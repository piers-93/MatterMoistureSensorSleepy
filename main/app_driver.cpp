/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <esp_log.h>
#include <esp_matter.h>
#include <sdkconfig.h>
#include <esp_adc/adc_oneshot.h>
#include <esp_adc/adc_cali.h>
#include <esp_adc/adc_cali_scheme.h>
#include <driver/temperature_sensor.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <nvs.h>
#include <app_priv.h>

using namespace chip::app::Clusters;
using namespace esp_matter;

static constexpr char *TAG = "app_driver";


#define MOISTURE_DRY_VALUE      2690  // ADC value for dry soil (in mV) - CALIBRATE: measure in dry air
#define MOISTURE_WET_VALUE      1170   // ADC value for wet soil (in mV) - CALIBRATE: measure in water
#define SENSOR_WARMUP_MS        300   // Time for sensor to stabilize after power-on

/* Battery measurement configuration */
#define BATTERY_ADC_CHANNEL     ADC_CHANNEL_0  // GPIO1
#define VOLTAGE_DIVIDER_RATIO   1.4256f           // 4.7M oben, 2M unten: (4.7M + 2M)/2M
#define BATTERY_FULL_VOLTAGE    4.15f              // Fully charged battery voltage
#define BATTERY_EMPTY_VOLTAGE   3.0f              // Empty battery voltage

/* NVS calibration storage */
#define CAL_NVS_NAMESPACE       "moisture_cal"
#define CAL_NVS_KEY_DRY         "dry_mv"
#define CAL_NVS_KEY_WET         "wet_mv"

/* Calibration window */
#define CALIBRATION_DURATION_MS  30000
#define CALIBRATION_SAMPLE_MS      500

/* Runtime calibration values (overridden by NVS if available) */
static int s_dry_value = MOISTURE_DRY_VALUE;
static int s_wet_value = MOISTURE_WET_VALUE;

static bool measurement_in_progress = false;
static bool s_calibration_running   = false;
app_driver_handle_t app_driver_moisture_sensor_init()
{
    /* Configure GPIO for sensor power control with MAXIMUM drive strength */
    gpio_config_t io_conf = {};
    io_conf.intr_type = GPIO_INTR_DISABLE;
    io_conf.mode = GPIO_MODE_OUTPUT;
    io_conf.pin_bit_mask = (1ULL << CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.pull_up_en = GPIO_PULLUP_DISABLE;
    gpio_config(&io_conf);
    
    /* Set MAXIMUM drive strength (40mA) */
    gpio_set_drive_capability((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, GPIO_DRIVE_CAP_3);
    
    /* Start with sensor powered OFF */
    gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 0);
    
    /* Load calibration from NVS (falls back to compile-time defaults if not set) */
    nvs_handle_t cal_nvs;
    if (nvs_open(CAL_NVS_NAMESPACE, NVS_READONLY, &cal_nvs) == ESP_OK) {
        int32_t val;
        if (nvs_get_i32(cal_nvs, CAL_NVS_KEY_DRY, &val) == ESP_OK) s_dry_value = (int)val;
        if (nvs_get_i32(cal_nvs, CAL_NVS_KEY_WET, &val) == ESP_OK) s_wet_value = (int)val;
        nvs_close(cal_nvs);
    }
    ESP_LOGI(TAG, "Calibration values: dry=%d mV, wet=%d mV", s_dry_value, s_wet_value);

    /* Configure LED GPIO for calibration feedback */
    gpio_config_t led_conf = {};
    led_conf.intr_type    = GPIO_INTR_DISABLE;
    led_conf.mode         = GPIO_MODE_OUTPUT;
    led_conf.pin_bit_mask = (1ULL << CONFIG_CALIBRATION_LED_GPIO);
    led_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    led_conf.pull_up_en   = GPIO_PULLUP_DISABLE;
    gpio_config(&led_conf);
    gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, 0);

    ESP_LOGI(TAG, "Moisture sensor initialized - GPIO%d (ADC_CH%d)",
             CONFIG_MOISTURE_SENSOR_GPIO, CONFIG_MOISTURE_SENSOR_ADC_CHANNEL);
    ESP_LOGI(TAG, "Sensor power control: GPIO%d (starts LOW/OFF, drive=40mA)",
             CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    ESP_LOGI(TAG, "Calibration LED: GPIO%d", CONFIG_CALIBRATION_LED_GPIO);
    return (app_driver_handle_t)1;
}

float app_driver_get_moisture_percentage()
{
    if (measurement_in_progress) {
        ESP_LOGW(TAG, "!!! Measurement already in progress - SKIPPING !!!");
        return 0;
    }
    
    measurement_in_progress = true;
    ESP_LOGI(TAG, "[LOCK] Measurement started");
    
    adc_oneshot_unit_handle_t adc1_handle = NULL;
    adc_cali_handle_t adc1_cali_handle = NULL;
    int adc_raw = 0;
    int voltage = 0;
    float moisture = 0;
    
    ESP_LOGI(TAG, "Starting moisture measurement...");
    int64_t start_time = esp_timer_get_time();
    
    /* FIRST: Initialize ADC (before GPIO to avoid interference) */
    ESP_LOGI(TAG, "Step 1: Initializing ADC...");
    ESP_LOGI(TAG, "CONFIG: Sensor GPIO=%d, ADC Channel=%d, Power GPIO=%d", 
             CONFIG_MOISTURE_SENSOR_GPIO, CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, 
             CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    
    adc_oneshot_unit_init_cfg_t init_config1 = {
        .unit_id = ADC_UNIT_1,
    };
    if (adc_oneshot_new_unit(&init_config1, &adc1_handle) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize ADC");
        measurement_in_progress = false;
        return 0;
    }
    
    ESP_LOGI(TAG, "ADC Unit initialized successfully");
    
    /* SECOND: Turn sensor power ON */
    int64_t before_gpio = esp_timer_get_time();
    gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 1);
    gpio_hold_en((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    
    ESP_LOGI(TAG, "Step 2: GPIO%d -> HIGH (sensor powered ON)", CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    
    vTaskDelay(pdMS_TO_TICKS(SENSOR_WARMUP_MS));  // Wait for sensor to stabilize
    
    int64_t after_delay = esp_timer_get_time();
    ESP_LOGI(TAG, "After delay: %.1f ms", (after_delay - before_gpio) / 1000.0);
    
    /* Configure ADC channel with ATTEN_DB_12 for 0-3.3V range */
    adc_oneshot_chan_cfg_t config = {
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    if (adc_oneshot_config_channel(adc1_handle, (adc_channel_t)CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to configure ADC channel");
        adc_oneshot_del_unit(adc1_handle);
        gpio_hold_dis((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
        gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 0);
        measurement_in_progress = false;
        return 0;
    }
    
    /* THIRD: Read ADC - do 5 dummy reads to settle, then take real reading */
    ESP_LOGI(TAG, "Step 3: Reading ADC Channel %d...", CONFIG_MOISTURE_SENSOR_ADC_CHANNEL);
    

    int dummy;
    for (int i = 0; i < 5; i++) {
        adc_oneshot_read(adc1_handle, (adc_channel_t)CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, &dummy);
    }
    
    adc_raw = 0;
    for (int i = 0; i < 15; i++) {
        int reading;
        adc_oneshot_read(adc1_handle, (adc_channel_t)CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, &reading);
        adc_raw += reading;
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    adc_raw /= 15;

    ESP_LOGI(TAG, "ADC raw value: %d", adc_raw);
    
    /* Setup ADC calibration */
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    adc_cali_curve_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_curve_fitting(&cali_config, &adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    adc_cali_line_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_line_fitting(&cali_config, &adc1_cali_handle);
#endif
    
    /* Convert to voltage if calibration is available */
    if (adc1_cali_handle) {
        adc_cali_raw_to_voltage(adc1_cali_handle, adc_raw, &voltage);
    } else {
        /* Rough conversion without calibration */
        float voltage = (float)adc_raw * 3300.0f / 4095.0f;
    }
    
    ESP_LOGI(TAG, "ADC raw: %d, Voltage: %d mV", adc_raw, voltage);
    
    /* Convert voltage to moisture percentage (0-100%)
     * Higher voltage = drier soil, lower voltage = wetter soil
     */
    moisture = 100.0f - ((float)(voltage - s_wet_value) / (float)(s_dry_value - s_wet_value) * 100.0f);
    
    /* Clamp to 0-100% range */
    if (moisture < 0) moisture = 0;
    if (moisture > 100) moisture = 100;
    
    /* Clean up ADC resources */
    if (adc1_cali_handle) {
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
        adc_cali_delete_scheme_curve_fitting(adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
        adc_cali_delete_scheme_line_fitting(adc1_cali_handle);
#endif
    }
    adc_oneshot_del_unit(adc1_handle);
    
    /* Release GPIO hold and turn sensor power OFF */
    gpio_hold_dis((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 0);
    int64_t end_time = esp_timer_get_time();
    ESP_LOGI(TAG, "GPIO%d -> LOW (sensor powered OFF) at %lld us", 
             CONFIG_MOISTURE_SENSOR_POWER_GPIO, end_time);
    ESP_LOGI(TAG, "Total measurement time: %.1f ms", (end_time - start_time) / 1000.0);
    
    ESP_LOGI(TAG, "Moisture: %.1f%%", moisture);
    
    measurement_in_progress = false;
    ESP_LOGI(TAG, "[UNLOCK] Measurement completed");
    return moisture;
}

/**
 * @brief Measure battery voltage via ADC with voltage divider
 * 
 * Battery voltage is connected via 300k/100k voltage divider to GPIO1 (ADC1_CH0)
 * Measured voltage = Battery voltage / 4
 * 
 * @return Battery voltage in volts (e.g., 3.0 for 3.0V battery)
 */
float app_driver_get_battery_voltage()
{
    adc_oneshot_unit_handle_t adc1_handle = NULL;
    adc_cali_handle_t adc1_cali_handle = NULL;
    int adc_raw = 0;
    int voltage_mv = 0;
    float battery_voltage = 0.0f;
    
    ESP_LOGI(TAG, "Starting battery voltage measurement...");
    
    /* Initialize ADC Unit */
    adc_oneshot_unit_init_cfg_t init_config = {
        .unit_id = ADC_UNIT_1,
    };
    if (adc_oneshot_new_unit(&init_config, &adc1_handle) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize ADC for battery measurement");
        return 0.0f;
    }
    
    /* Configure ADC channel for battery measurement */
    adc_oneshot_chan_cfg_t config = {
        .atten = ADC_ATTEN_DB_12,      // 0-3.3V range (good for battery/4 = 0.75-1.1V)
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    if (adc_oneshot_config_channel(adc1_handle, BATTERY_ADC_CHANNEL, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to configure battery ADC channel");
        adc_oneshot_del_unit(adc1_handle);
        return 0.0f;
    }
    
    /* Flush ADC with dummy reads */
    int dummy;
    for (int i = 0; i < 5; i++) {
        adc_oneshot_read(adc1_handle, BATTERY_ADC_CHANNEL, &dummy);
    }
    
    /* Read battery voltage (average of 5 readings) */
    adc_raw = 0;
    for (int i = 0; i < 5; i++) {
        int reading;
        adc_oneshot_read(adc1_handle, BATTERY_ADC_CHANNEL, &reading);
        adc_raw += reading;
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    adc_raw /= 5;
    
    /* Setup ADC calibration */
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    adc_cali_curve_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_curve_fitting(&cali_config, &adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    adc_cali_line_fitting_config_t cali_config = {
        .unit_id = ADC_UNIT_1,
        .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_line_fitting(&cali_config, &adc1_cali_handle);
#endif
    
    /* Convert raw ADC to voltage */
    if (adc1_cali_handle) {
        adc_cali_raw_to_voltage(adc1_cali_handle, adc_raw, &voltage_mv);
    } else {
        voltage_mv = adc_raw * 3300 / 4095;
    }
    
    /* Apply voltage divider ratio to get actual battery voltage */
    battery_voltage = (float)voltage_mv * VOLTAGE_DIVIDER_RATIO / 1000.0f;
    
    ESP_LOGI(TAG, "Battery: ADC raw=%d, ADC voltage=%d mV, Battery voltage=%.2f V", 
             adc_raw, voltage_mv, battery_voltage);
    
    /* Clean up */
    if (adc1_cali_handle) {
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
        adc_cali_delete_scheme_curve_fitting(adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
        adc_cali_delete_scheme_line_fitting(adc1_cali_handle);
#endif
    }
    adc_oneshot_del_unit(adc1_handle);
    
    return battery_voltage;
}

/**
 * @brief Convert battery voltage to percentage
 * 
 * @param voltage Battery voltage in volts
 * @return Battery percentage (0-100%)
 */
float app_driver_battery_voltage_to_percent(float voltage)
{
    float percent = ((voltage - BATTERY_EMPTY_VOLTAGE) / (BATTERY_FULL_VOLTAGE - BATTERY_EMPTY_VOLTAGE)) * 100.0f;
    
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    
    return percent;
}
/* ---- Calibration ---- */

static void calibration_task(void *arg)
{
    /* Wait for any ongoing normal measurement to finish */
    while (measurement_in_progress) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    measurement_in_progress = true;

    ESP_LOGI(TAG, "=== Calibration started: move sensor between DRY and WET for %d s ===",
             CALIBRATION_DURATION_MS / 1000);

    adc_oneshot_unit_handle_t adc1_handle = NULL;
    adc_cali_handle_t adc1_cali_handle = NULL;

    adc_oneshot_unit_init_cfg_t init_config = { .unit_id = ADC_UNIT_1 };
    if (adc_oneshot_new_unit(&init_config, &adc1_handle) != ESP_OK) {
        ESP_LOGE(TAG, "Calibration: ADC init failed");
        measurement_in_progress = false;
        s_calibration_running   = false;
        vTaskDelete(NULL);
        return;
    }

    adc_oneshot_chan_cfg_t config = {
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_oneshot_config_channel(adc1_handle, (adc_channel_t)CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, &config);

#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    adc_cali_curve_fitting_config_t cali_config = {
        .unit_id  = ADC_UNIT_1,
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_curve_fitting(&cali_config, &adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    adc_cali_line_fitting_config_t cali_config = {
        .unit_id  = ADC_UNIT_1,
        .atten    = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT,
    };
    adc_cali_create_scheme_line_fitting(&cali_config, &adc1_cali_handle);
#endif

    /* Power sensor on */
    gpio_hold_dis((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 1);
    gpio_hold_en((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    vTaskDelay(pdMS_TO_TICKS(SENSOR_WARMUP_MS));

    const int num_samples = CALIBRATION_DURATION_MS / CALIBRATION_SAMPLE_MS;
    int max_mv = 0;
    int min_mv = 9999;

    for (int i = 0; i < num_samples; i++) {
        /* Blink LED at 1 Hz (toggles every CALIBRATION_SAMPLE_MS = 500 ms).
         * gpio_hold_en keeps the level stable during light sleep. */
        gpio_hold_dis((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);
        gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, i % 2);
        gpio_hold_en((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);

        int raw = 0;
        adc_oneshot_read(adc1_handle, (adc_channel_t)CONFIG_MOISTURE_SENSOR_ADC_CHANNEL, &raw);

        int mv = 0;
        if (adc1_cali_handle) {
            adc_cali_raw_to_voltage(adc1_cali_handle, raw, &mv);
        } else {
            mv = raw * 3300 / 4095;
        }

        if (mv > max_mv) max_mv = mv;
        if (mv < min_mv) min_mv = mv;

        ESP_LOGI(TAG, "Cal [%2d/%d] %d mV  (min=%d, max=%d)",
                 i + 1, num_samples, mv, min_mv, max_mv);
        vTaskDelay(pdMS_TO_TICKS(CALIBRATION_SAMPLE_MS));
    }

    /* Ensure LED is OFF after loop (last iteration may have left it ON) */
    gpio_hold_dis((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, 0);

    /* Power sensor off */
    gpio_hold_dis((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_MOISTURE_SENSOR_POWER_GPIO, 0);

    /* Cleanup ADC */
    if (adc1_cali_handle) {
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
        adc_cali_delete_scheme_curve_fitting(adc1_cali_handle);
#elif ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
        adc_cali_delete_scheme_line_fitting(adc1_cali_handle);
#endif
    }
    adc_oneshot_del_unit(adc1_handle);
    measurement_in_progress = false;

    /* Validate: require at least 1000 mV spread */
    if ((max_mv - min_mv) < 1000) {
        ESP_LOGW(TAG, "Calibration discarded: spread only %d mV (need >=1000 mV). "
                      "Move sensor between dry air and water during the window.",
                 max_mv - min_mv);
        /* 3 rapid blinks = error */
        for (int i = 0; i < 6; i++) {
            gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, i % 2);
            vTaskDelay(pdMS_TO_TICKS(150));
        }
        gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, 0);
        s_calibration_running = false;
        vTaskDelete(NULL);
        return;
    }

    /* Apply to RAM */
    s_dry_value = max_mv;
    s_wet_value = min_mv;

    /* Persist to NVS */
    nvs_handle_t cal_nvs;
    if (nvs_open(CAL_NVS_NAMESPACE, NVS_READWRITE, &cal_nvs) == ESP_OK) {
        nvs_set_i32(cal_nvs, CAL_NVS_KEY_DRY, (int32_t)s_dry_value);
        nvs_set_i32(cal_nvs, CAL_NVS_KEY_WET, (int32_t)s_wet_value);
        nvs_commit(cal_nvs);
        nvs_close(cal_nvs);
    }
    ESP_LOGI(TAG, "=== Calibration saved: dry=%d mV, wet=%d mV ===", s_dry_value, s_wet_value);

    /* LED solid 3 s = success (start from OFF so the ON transition is clearly visible) */
    vTaskDelay(pdMS_TO_TICKS(300));
    gpio_hold_dis((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, 1);
    gpio_hold_en((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);
    vTaskDelay(pdMS_TO_TICKS(3000));
    gpio_hold_dis((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO);
    gpio_set_level((gpio_num_t)CONFIG_CALIBRATION_LED_GPIO, 0);

    s_calibration_running = false;
    vTaskDelete(NULL);
}

void app_driver_calibration_start(void)
{
    if (s_calibration_running) {
        ESP_LOGW(TAG, "Calibration already running");
        return;
    }
    s_calibration_running = true;
    xTaskCreate(calibration_task, "cal_task", 4096, NULL, 5, NULL);
}

float app_driver_get_temperature()
{
    temperature_sensor_handle_t tsens = NULL;
    temperature_sensor_config_t tsens_config = {
        .range_min = -10,
        .range_max = 80,
    };
    float temp_celsius = 0.0f;

    if (temperature_sensor_install(&tsens_config, &tsens) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to install internal temperature sensor");
        return 0.0f;
    }
    if (temperature_sensor_enable(tsens) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to enable internal temperature sensor");
        temperature_sensor_uninstall(tsens);
        return 0.0f;
    }
    temperature_sensor_get_celsius(tsens, &temp_celsius);
    temperature_sensor_disable(tsens);
    temperature_sensor_uninstall(tsens);

    ESP_LOGI(TAG, "Internal temperature: %.1f °C", temp_celsius);
    return temp_celsius;
}