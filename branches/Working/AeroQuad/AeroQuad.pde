 /*
  AeroQuad v1.6 - March 2010
  www.AeroQuad.com
  Copyright (c) 2010 Ted Carancho.  All rights reserved.
  An Open Source Arduino based quadrocopter.
 
  This program is free software: you can redistribute it and/or modify 
  it under the terms of the GNU General Public License as published by 
  the Free Software Foundation, either version 3 of the License, or 
  (at your option) any later version. 

  This program is distributed in the hope that it will be useful, 
  but WITHOUT ANY WARRANTY; without even the implied warranty of 
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the 
  GNU General Public License for more details. 

  You should have received a copy of the GNU General Public License 
  along with this program. If not, see <http://www.gnu.org/licenses/>. 
*/

#include "AeroQuad.h"

#include "Eeprom.h"
Eeprom eeprom;

#include "Sensors.h"
Sensors sensors;

#include "FlightCommand.h"
FlightCommand_2009 flightcommand;
//Receiver_Mega receiver;
//SIGNAL(PCINT0_vect) {receiver.measurePulseWidthISR(0);}
//SIGNAL(PCINT1_vect) {receiver.measurePulseWidthISR(1);}
//SIGNAL(PCINT2_vect) {receiver.measurePulseWidthISR(2);}

#include "FlightControl.h"
FlightControl flightcontrol;

#include "Motors.h"
Motors_PWM motors;
//Motors_I2C motors;

#include "SerialComs.h"
SerialComs serialcoms;

//#include "Blinkie.h"
//Blinkie blinkie;

// ************************************************************
// ********************** Setup AeroQuad **********************
// ************************************************************
void setup() {
  sensors.initialize(2, 0);// Setup and calibrate sensors, read every 2ms (500Hz)

  flightcontrol.initialize(2,1); // Calculate motor commands every 2ms (500Hz), but offset by 1 ms
  flightcontrol.disableAutoLevel();
  flightcontrol.disableHeadingHold();
  
  flightcommand.initialize(100,25); // Setup receiver pins for pin change interrupts and read every 100ms (10Hz) starting

  motors.initialize(2,1); // Configure motors and command motors every 2ms (500Hz)

  serialcoms.assignSerialPort(&Serial); // Configure the serial port 1
  serialcoms.initialize(100, 50); // Read commands/telemetry every 100ms (10Hz) starting
  
  // Use this class to learn how SubSystem works
  blinkie.initialize(1000,0); // Start blinking the LED every 1000ms (1Hz)
}

// ************************************************************
// ******************** Main AeroQuad Loop ********************
// ************************************************************
void loop () {
  currentTime = millis();
  
  // Measure sensor output at 500Hz rate
  sensors.process(currentTime);
  
  // Calculate flight angle to AeroQuad at 500Hz rate
  attitude.process(currentTime);
  
  // Process sensor data and generate motor commands at 500Hz rate
  flightcontrol.process(currentTime);
  
  // Read R/C receiver and execute pilot commands at 100Hz rate
  receiver.process(currentTime); 
  
  // Command motors at 500Hz rate
  motors.process(currentTime);
  
  // Process serial command and telemetry at 10Hz rate
  serialcoms.process(currentTime); 
}