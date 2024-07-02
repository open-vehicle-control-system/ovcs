#ifndef MAIN_H
#define MAIN_H

#include <Arduino.h>
#include <ACAN2517.h>
#include <SPI.h>
#include <EEPROM.h>
#include <CRC32.h>

#define ON 1
#define OFF 0
#define OUTPUT_PIN_MODE 0x00
#define I2C_CLOCK_FREQUENCY 100000
#define PIN_STATUS_FRAME_FREQUENCY_MS 10
#define ADOPTION_BUTTON_PIN 2
#define ADOPTION_FRAME_ID 0x700
#define CONFIGURATION_EEPROM_ADDRESS 0
#define CONFIGURATION_CRC_EEPROM_ADDRESS 64
#define CONFIGURATION_BYTE_SIZE 8

static const byte MCP2517_CS  = 10;
static const byte MCP2517_INT = 3;

#endif