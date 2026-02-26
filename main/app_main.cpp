/*
   This example code is in the Public Domain (or CC0 licensed, at your option.)

   Unless required by applicable law or agreed to in writing, this
   software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, either express or implied.
*/

#include <esp_err.h>
#include <esp_log.h>
#include <nvs_flash.h>
#if CONFIG_PM_ENABLE
#include <esp_pm.h>
#endif

#include <esp_matter.h>
#include <esp_matter_ota.h>

#include <common_macros.h>
#include <app_priv.h>
#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
#include <platform/ESP32/OpenthreadLauncher.h>
#endif

#include <app/server/CommissioningWindowManager.h>
#include <app/server/Server.h>
#include <app/icd/server/ICDStateObserver.h>

static const char *TAG = "app_main";

using namespace esp_matter;
using namespace esp_matter::attribute;
using namespace esp_matter::endpoint;
using namespace esp_matter::cluster;
using namespace chip::app::Clusters;

static uint16_t moisture_endpoint_id = 0;

constexpr auto k_timeout_seconds = 300;

static void app_event_cb(const ChipDeviceEvent *event, intptr_t arg)
{
    switch (event->Type) {
    case chip::DeviceLayer::DeviceEventType::kInterfaceIpAddressChanged:
        ESP_LOGI(TAG, "Interface IP Address changed");
        break;

    case chip::DeviceLayer::DeviceEventType::kCommissioningComplete:
        ESP_LOGI(TAG, "Commissioning complete");
        break;

    case chip::DeviceLayer::DeviceEventType::kFailSafeTimerExpired:
        ESP_LOGI(TAG, "Commissioning failed, fail safe timer expired");
        break;

    case chip::DeviceLayer::DeviceEventType::kCommissioningSessionStarted:
        ESP_LOGI(TAG, "Commissioning session started");
        break;

    case chip::DeviceLayer::DeviceEventType::kCommissioningSessionStopped:
        ESP_LOGI(TAG, "Commissioning session stopped");
        break;

    case chip::DeviceLayer::DeviceEventType::kCommissioningWindowOpened:
        ESP_LOGI(TAG, "Commissioning window opened");
        break;

    case chip::DeviceLayer::DeviceEventType::kCommissioningWindowClosed:
        ESP_LOGI(TAG, "Commissioning window closed");
        break;

    case chip::DeviceLayer::DeviceEventType::kFabricRemoved:
        {
            ESP_LOGI(TAG, "Fabric removed successfully");
            if (chip::Server::GetInstance().GetFabricTable().FabricCount() == 0)
            {
                chip::CommissioningWindowManager & commissionMgr = chip::Server::GetInstance().GetCommissioningWindowManager();
                constexpr auto kTimeoutSeconds = chip::System::Clock::Seconds16(k_timeout_seconds);
                if (!commissionMgr.IsCommissioningWindowOpen())
                {
                    /* After removing last fabric, this example does not remove the Wi-Fi credentials
                     * and still has IP connectivity so, only advertising on DNS-SD.
                     */
                    CHIP_ERROR err = commissionMgr.OpenBasicCommissioningWindow(kTimeoutSeconds,
                                                    chip::CommissioningWindowAdvertisement::kDnssdOnly);
                    if (err != CHIP_NO_ERROR)
                    {
                        ESP_LOGE(TAG, "Failed to open commissioning window, err:%" CHIP_ERROR_FORMAT, err.Format());
                    }
                }
            }
        break;
        }

    case chip::DeviceLayer::DeviceEventType::kFabricWillBeRemoved:
        ESP_LOGI(TAG, "Fabric will be removed");
        break;

    case chip::DeviceLayer::DeviceEventType::kFabricUpdated:
        ESP_LOGI(TAG, "Fabric is updated");
        break;

    case chip::DeviceLayer::DeviceEventType::kFabricCommitted:
        ESP_LOGI(TAG, "Fabric is committed");
        break;
    default:
        break;
    }
}

static esp_err_t app_identification_cb(identification::callback_type_t type, uint16_t endpoint_id, uint8_t effect_id,
                                       uint8_t effect_variant, void *priv_data)
{
    ESP_LOGI(TAG, "Identification callback: type: %u, effect: %u, variant: %u", type, effect_id, effect_variant);
    return ESP_OK;
}

static esp_err_t app_attribute_update_cb(attribute::callback_type_t type, uint16_t endpoint_id, uint32_t cluster_id,
                                         uint32_t attribute_id, esp_matter_attr_val_t *val, void *priv_data)
{
    esp_err_t err = ESP_OK;

    if (type == PRE_UPDATE) {
        /* Driver update */
    }

    return err;
}

/**
 * Perform moisture and battery measurement.
 * Called from ScheduleWork on the CHIP task when ICD enters active mode.
 */
static void perform_measurement(intptr_t)
{
    ESP_LOGI(TAG, "=== ICD-synced measurement starting ===");
    
    /* Read moisture sensor (sensor will be powered on/off inside this function) */
    float moisture = app_driver_get_moisture_percentage();
    
    /* Round to whole percent, then convert to Matter format (0.01% units) */
    uint16_t rounded_percent = (uint16_t)(moisture + 0.5f);
    uint16_t measured_value = rounded_percent * 100;
    
    /* Update Matter attribute */
    esp_matter_attr_val_t val = esp_matter_nullable_uint16(measured_value);
    esp_err_t update_err = attribute::update(moisture_endpoint_id, RelativeHumidityMeasurement::Id,
                     RelativeHumidityMeasurement::Attributes::MeasuredValue::Id, &val);
    
    if (update_err == ESP_OK) {
        ESP_LOGI(TAG, "Updated moisture: %d%%", rounded_percent);
    } else {
        ESP_LOGE(TAG, "Failed to update moisture attribute, err: %d", update_err);
    }
    
    /* Read battery voltage */
    float battery_voltage = app_driver_get_battery_voltage();
    float battery_percent = app_driver_battery_voltage_to_percent(battery_voltage);
    
    /* BatPercentRemaining: 0-200 (0.5% resolution, 200 = 100%) */
    uint8_t bat_percent_remaining = (uint8_t)(battery_percent * 2);
    esp_matter_attr_val_t bat_percent_val = esp_matter_nullable_uint8(bat_percent_remaining);
    attribute::update(0, PowerSource::Id, PowerSource::Attributes::BatPercentRemaining::Id, &bat_percent_val);
    
    /* BatVoltage: in millivolts */
    uint32_t bat_voltage_mv = (uint32_t)(battery_voltage * 1000);
    esp_matter_attr_val_t bat_voltage_val = esp_matter_nullable_uint32(bat_voltage_mv);
    attribute::update(0, PowerSource::Id, PowerSource::Attributes::BatVoltage::Id, &bat_voltage_val);
    
    ESP_LOGI(TAG, "Battery: %.2fV (%.0f%%), BatPercentRemaining=%d, BatVoltage=%u mV", 
             battery_voltage, battery_percent, bat_percent_remaining, bat_voltage_mv);
}

/**
 * ICD State Observer: Synchronizes sensor measurements with Matter ICD wake-up cycles.
 * Instead of running an independent timer (which causes separate CPU wake-ups),
 * we piggyback measurements onto the ICD's existing idle->active transitions.
 * This eliminates redundant wake-ups and reduces power consumption.
 */
class MoistureMeasurementObserver : public chip::app::ICDStateObserver
{
public:
    void OnEnterActiveMode() override
    {
        ESP_LOGI(TAG, "ICD entered active mode - scheduling measurement");
        chip::DeviceLayer::PlatformMgr().ScheduleWork(perform_measurement);
    }

    void OnEnterIdleMode() override {}
    void OnTransitionToIdle() override {}
    void OnICDModeChange() override {}
};

static MoistureMeasurementObserver sMoistureObserver;

extern "C" void app_main()
{
    esp_err_t err = ESP_OK;

    /* Initialize the ESP NVS layer */
    nvs_flash_init();

#if CONFIG_PM_ENABLE
    esp_pm_config_t pm_config = {
        .max_freq_mhz = CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ,
        .min_freq_mhz = CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ,
#if CONFIG_FREERTOS_USE_TICKLESS_IDLE
        .light_sleep_enable = true
#endif
    };
    err = esp_pm_configure(&pm_config);
#endif
    /* Initialize moisture sensor driver */
    app_driver_moisture_sensor_init();
    
    /* Create a Matter node and add the mandatory Root Node device type on endpoint 0 */
    node::config_t node_config;
    node_t *node = node::create(&node_config, app_attribute_update_cb, app_identification_cb);
    ABORT_APP_ON_FAILURE(node != nullptr, ESP_LOGE(TAG, "Failed to create Matter node"));

    /* Create humidity sensor endpoint (we use RelativeHumidityMeasurement cluster for soil moisture) */
    humidity_sensor::config_t sensor_config;
    endpoint_t *app_endpoint = humidity_sensor::create(node, &sensor_config, ENDPOINT_FLAG_NONE, NULL);
    ABORT_APP_ON_FAILURE(app_endpoint != nullptr, ESP_LOGE(TAG, "Failed to create humidity sensor endpoint"));
    
    moisture_endpoint_id = endpoint::get_id(app_endpoint);
    ESP_LOGI(TAG, "Moisture sensor endpoint created with ID: %d", moisture_endpoint_id);

    /* Add PowerSource cluster to root node (endpoint 0) for battery monitoring */
    endpoint_t *root_endpoint = endpoint::get(node, 0);
    ABORT_APP_ON_FAILURE(root_endpoint != nullptr, ESP_LOGE(TAG, "Failed to get root endpoint"));
    
    cluster_t *power_source_cluster = cluster::create(root_endpoint, PowerSource::Id, CLUSTER_FLAG_SERVER);
    if (power_source_cluster) {
        // Battery attributes
        cluster::power_source::attribute::create_status(power_source_cluster, (uint8_t)PowerSource::PowerSourceStatusEnum::kActive);
        cluster::power_source::attribute::create_order(power_source_cluster, 0, 0, 255);
        cluster::power_source::attribute::create_description(power_source_cluster, "Battery", 7);
        
        // Battery-specific attributes (in millivolts: 3000-4200 mV for LiPo)
        cluster::power_source::attribute::create_bat_voltage(power_source_cluster, nullable<uint32_t>(3700), nullable<uint32_t>(3000), nullable<uint32_t>(4200));
        cluster::power_source::attribute::create_bat_percent_remaining(power_source_cluster, nullable<uint8_t>(200), nullable<uint8_t>(0), nullable<uint8_t>(200));
        cluster::power_source::attribute::create_bat_charge_level(power_source_cluster, (uint8_t)PowerSource::BatChargeLevelEnum::kOk);
        
        ESP_LOGI(TAG, "Power Source cluster added to root endpoint");
    } else {
        ESP_LOGE(TAG, "Failed to create Power Source cluster");
    }

#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
    /* Set OpenThread platform config */
    esp_openthread_platform_config_t config = {
        .radio_config = ESP_OPENTHREAD_DEFAULT_RADIO_CONFIG(),
        .host_config = ESP_OPENTHREAD_DEFAULT_HOST_CONFIG(),
        .port_config = ESP_OPENTHREAD_DEFAULT_PORT_CONFIG(),
    };
    set_openthread_platform_config(&config);
#endif

    /* Matter start */
    err = esp_matter::start(app_event_cb);
    ABORT_APP_ON_FAILURE(err == ESP_OK, ESP_LOGE(TAG, "Failed to start Matter, err:%d", err));
    
    /* Perform initial moisture measurement */
    ESP_LOGI(TAG, "Performing initial moisture measurement...");
    float initial_moisture = app_driver_get_moisture_percentage();
    uint16_t initial_rounded = (uint16_t)(initial_moisture + 0.5f);
    uint16_t initial_value = initial_rounded * 100;
    esp_matter_attr_val_t initial_val = esp_matter_nullable_uint16(initial_value);
    attribute::update(moisture_endpoint_id, RelativeHumidityMeasurement::Id,
                     RelativeHumidityMeasurement::Attributes::MeasuredValue::Id, &initial_val);
    ESP_LOGI(TAG, "Initial moisture: %d%%", initial_rounded);
    
    /* Perform initial battery measurement */
    ESP_LOGI(TAG, "Performing initial battery measurement...");
    float initial_battery_voltage = app_driver_get_battery_voltage();
    float initial_battery_percent = app_driver_battery_voltage_to_percent(initial_battery_voltage);
    
    uint8_t initial_bat_percent = (uint8_t)(initial_battery_percent * 2);
    uint32_t initial_bat_voltage = (uint32_t)(initial_battery_voltage * 1000);
    
    esp_matter_attr_val_t bat_percent_val = esp_matter_nullable_uint8(initial_bat_percent);
    attribute::update(0, PowerSource::Id, PowerSource::Attributes::BatPercentRemaining::Id, &bat_percent_val);
    
    esp_matter_attr_val_t bat_voltage_val = esp_matter_nullable_uint32(initial_bat_voltage);
    attribute::update(0, PowerSource::Id, PowerSource::Attributes::BatVoltage::Id, &bat_voltage_val);
    
    ESP_LOGI(TAG, "Initial battery: %.2fV (%.0f%%)", initial_battery_voltage, initial_battery_percent);
    
    /* Register ICD observer to synchronize measurements with Matter wake-up cycles.
     * Measurement interval is now controlled by CONFIG_ICD_IDLE_MODE_INTERVAL_SEC.
     * This eliminates the separate esp_timer wake-up that caused extra current spikes. */
    chip::Server::GetInstance().GetICDManager().RegisterObserver(&sMoistureObserver);
    ESP_LOGI(TAG, "ICD measurement observer registered (interval: %d s via ICD_IDLE_MODE_INTERVAL)",
             CONFIG_ICD_IDLE_MODE_INTERVAL_SEC);
    ESP_LOGI(TAG, "Power optimization: Sensor measurement synced with ICD active mode");
}
