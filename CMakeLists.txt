# The following lines of boilerplate have to be in your project's
# CMakeLists in this exact order for cmake to work correctly
cmake_minimum_required(VERSION 3.5)

if(NOT DEFINED ENV{ESP_MATTER_PATH})
    message(FATAL_ERROR "Please set ESP_MATTER_PATH to the path of esp-matter repo")
endif(NOT DEFINED ENV{ESP_MATTER_PATH})

# "Firmware Version" in Homeassistant, PROJECT_VER_NUMBER is used for OTA updates, PROJECT_VER is used for display in Homeassistant and the Matter Commissioning App. Both are defined here to ensure they are always in sync. 
set(PROJECT_VER "2.1")
set(PROJECT_VER_NUMBER 3)

set(ESP_MATTER_PATH $ENV{ESP_MATTER_PATH})
set(MATTER_SDK_PATH ${ESP_MATTER_PATH}/connectedhomeip/connectedhomeip)

# This should be done before using the IDF_TARGET variable.
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

set(EXTRA_COMPONENT_DIRS
    "${ESP_MATTER_PATH}/examples/common"
    "${MATTER_SDK_PATH}/config/esp32/components"
    "${ESP_MATTER_PATH}/components")

project(icd_app)

# Matter SoftwareVersion / SoftwareVersionString werden direkt aus dieser
# App-Binary genommen (Basic Information Cluster). So reicht ein einfaches
# OTA/Re-Flash der app.bin fuer ein Firmware-Update – kein Re-Pairing noetig,
# Factory-Partition bleibt unveraendert.
idf_build_set_property(COMPILE_DEFINITIONS
    "CHIP_DEVICE_CONFIG_DEVICE_SOFTWARE_VERSION=${PROJECT_VER_NUMBER}" APPEND)
idf_build_set_property(COMPILE_DEFINITIONS
    "CHIP_DEVICE_CONFIG_DEVICE_SOFTWARE_VERSION_STRING=\"${PROJECT_VER}\"" APPEND)

idf_build_set_property(CXX_COMPILE_OPTIONS "-std=gnu++17;-Os;-DCHIP_HAVE_CONFIG_H;-DCONFIG_OPENTHREAD_CONFIG_SRP_CLIENT_BUFFERS_MAX_SERVICES=5;-Wno-overloaded-virtual" APPEND)
idf_build_set_property(C_COMPILE_OPTIONS "-Os;-DCONFIG_OPENTHREAD_CONFIG_SRP_CLIENT_BUFFERS_MAX_SERVICES=5" APPEND)
# For RISCV chips, project_include.cmake sets -Wno-format, but does not clear various
# flags that depend on -Wformat
idf_build_set_property(COMPILE_OPTIONS "-Wno-format-nonliteral;-Wno-format-security" APPEND)
