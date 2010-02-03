/*
  AeroQuad v1.5 - Novmeber 2009
  www.AeroQuad.info
  Copyright (c) 2009 Ted Carancho.  All rights reserved.
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

// Define Flight Configuration
#define plusConfig
//#define XConfig

// Calibration At Start Up
#define CalibrationAtStartup
#define GyroCalibrationAtStartup

// Motor Control Method (ServoControl = higher ESC resolution, cooler motors, slight jitter in control, AnalogWrite = lower ESC resolution, warmer motors, no jitter)
// Before your first flight, to use the ServoControl method change the following line in Servo.h
// which can be found in \arduino-0017\hardware\libraries\Servo\Servo.h
// For camera stabilization off, update line 54 with: #define REFRESH_INTERVAL 8000
// For camera stabilization on, update line 54 with: #define REFRESH_INTERVAL 12000
// For ServoControl method connect AUXPIN=3, MOTORPIN=8 for compatibility with PCINT
//#define ServoControl // This is only compatible with Arduino 0017 or greater
// For AnalogWrite method connect AUXPIN=8, MOTORPIN=3
#define AnalogWrite

// Arduino Mega with AeroQuad Shield v1.x
// If you are using the Arduino Mega with an AeroQuad Shield v1.x, the receiver pins must be configured differently.
// Throttle = AI08, Aileron = AI09, Elevator = AI10, Rudder = AI11, Gear = AI12, AUX1 = AI13
#define Mega_AQ1x

// Camera Stabilization (experimental)
// Will move development to Arduino Mega (needs analogWrite support for additional pins)
//#define Camera

// Heading Hold (experimental)
#define HeadingHold // Currently uses yaw gyro which drifts over time, for Mega development will use magnetometer

// Auto Level (experimental)
#define AutoLevel

// 5DOF IMU Version
//#define OriginalIMU // Use this if you have the 5DOF IMU which uses the IDG300

// Yaw Gyro Type
#define IDG // InvenSense
//#define LPY // STMicroelectronics

// *************************************************************

#include <stdlib.h>
#include <math.h>
#include <EEPROM.h>
#include <Servo.h>
#include "EEPROM_AQ.h"
#include "Filter.h"
#include "PID.h"
#include "Receiver.h"
#include "Sensors.h"
#include "Motors.h"
#include "AeroQuad.h"

#include "GPS.h"
GPS gps;

#include "Blinkie.h"
Blinkie blinkie;

#include "SerialComs.h"
SerialComs serialcoms;

// ************************************************************
// ********************** Setup AeroQuad **********************
// ************************************************************

void setup() 
{
  analogReference(EXTERNAL); // Current external ref is connected to 3.3V
  pinMode (LEDPIN, OUTPUT);
  
  serialcoms.assignSerialPort(&Serial);
  serialcoms.assignSerialPort(&Serial1);
  serialcoms.initialize(100, 50);
  
  gps.assignSerialPort(&Serial2);
  gps.initialize(100, 75);
  
  //Initialize the blinkie SubSystem to run every 500 ms, with an offset of 0 ms
  blinkie.initialize(500,0);
    
  pinMode (AZPIN1, OUTPUT);
  digitalWrite(AZPIN1, LOW);

  pinMode (AZPIN2, OUTPUT);
  digitalWrite(AZPIN2, LOW);
  
  // Configure motors
  configureMotors();
  commandAllMotors(MINCOMMAND);

  // Read user values from EEPROM
  readEEPROM();
  
  // Setup receiver pins for pin change interrupts
  if (receiverLoop == ON)
  configureReceiver();
  
  //  Auto Zero Gyros
  autoZeroGyros();
  
  #ifdef CalibrationAtStartup
    // Calibrate sensors
    zeroGyros();
    zeroAccelerometers();
    zeroIntegralError();
  #endif
  #ifdef GyroCalibrationAtStartup
    zeroGyros();
  #endif
  levelAdjust[ROLL] = 0;
  levelAdjust[PITCH] = 0;
  
  // Camera stabilization setup
  #ifdef Camera
    rollCamera.attach(ROLLCAMERAPIN);
    pitchCamera.attach(PITCHCAMERAPIN);
  #endif
  
  // Complementary filter setup
  configureFilter(timeConstant);
  
  previousTime = millis();
  safetyCheck = 0;
}

// ************************************************************
// ******************** Main AeroQuad Loop ********************
// ************************************************************
void loop () {
  // Measure loop rate
  currentTime = millis();
  deltaTime = currentTime - previousTime;
  previousTime = currentTime;
  #ifdef DEBUG
    if (testSignal == LOW) testSignal = HIGH;
    else testSignal = LOW;
    digitalWrite(LEDPIN, testSignal);
  #endif
  
// ************************************************************************
// ****************** Transmitter/Receiver Command Loop *******************
// ************************************************************************
  if ((currentTime > (receiverTime + RECEIVERLOOPTIME)) && (receiverLoop == ON)) { // 10Hz
    // Buffer receiver values read from pin change interrupt handler
    for (channel = ROLL; channel < LASTCHANNEL; channel++)
      receiverData[channel] = (mTransmitter[channel] * readReceiver(receiverPin[channel])) + bTransmitter[channel];
    // Smooth the flight control transmitter inputs (roll, pitch, yaw, throttle)
    for (channel = ROLL; channel < LASTCHANNEL; channel++)
      transmitterCommandSmooth[channel] = smooth(receiverData[channel], transmitterCommandSmooth[channel], smoothTransmitter[channel]);
    // Reduce transmitter commands using xmitFactor and center around 1500
    for (channel = ROLL; channel < LASTAXIS; channel++)
      transmitterCommand[channel] = ((transmitterCommandSmooth[channel] - transmitterZero[channel]) * xmitFactor) + transmitterZero[channel];
    // No xmitFactor reduction applied for throttle, mode and AUX
    for (channel = THROTTLE; channel < LASTCHANNEL; channel++)
      transmitterCommand[channel] = transmitterCommandSmooth[channel];
    // Read quad configuration commands from transmitter when throttle down
    if (receiverData[THROTTLE] < MINCHECK) {
      zeroIntegralError();
      // Disarm motors (left stick lower left corner)
      if (receiverData[YAW] < MINCHECK && armed == 1) {
        armed = 0;
        commandAllMotors(MINCOMMAND);
      }    
      // Zero sensors (left stick lower left, right stick lower right corner)
      if ((receiverData[YAW] < MINCHECK) && (receiverData[ROLL] > MAXCHECK) && (receiverData[PITCH] < MINCHECK)) {
        autoZeroGyros();
        zeroGyros();
        zeroAccelerometers();
        zeroIntegralError();
        pulseMotors(3);
      }   
      // Arm motors (left stick lower right corner)
      if (receiverData[YAW] > MAXCHECK && armed == 0 && safetyCheck == 1) {
        armed = 1;
        zeroIntegralError();
        minCommand = MINTHROTTLE;
        transmitterCenter[PITCH] = receiverData[PITCH];
        transmitterCenter[ROLL] = receiverData[ROLL];
      }
      // Prevents accidental arming of motor output if no transmitter command received
      if (receiverData[YAW] > MINCHECK) safetyCheck = 1; 
    }
    // Prevents too little power applied to motors during hard manuevers
    if (receiverData[THROTTLE] > (MIDCOMMAND - MINDELTA)) minCommand = receiverData[THROTTLE] - MINDELTA;
    if (receiverData[THROTTLE] < MINTHROTTLE) minCommand = MINTHROTTLE;
    // Allows quad to do acrobatics by turning off opposite motors during hard manuevers
    //if ((receiverData[ROLL] < MINCHECK) || (receiverData[ROLL] > MAXCHECK) || (receiverData[PITCH] < MINCHECK) || (receiverData[PITCH] > MAXCHECK))
      //minCommand = MINTHROTTLE;
    receiverTime = currentTime;
  } 
//////////////////////////////////
// End of transmitter loop time //
//////////////////////////////////
  
// ***********************************************************
  // ********************* Analog Input Loop *******************
// ***********************************************************
  if ((currentTime > (analogInputTime + AILOOPTIME)) && (analogInputLoop == ON)) { // 500Hz
    // *********************** Read Sensors **********************
    // Apply low pass filter to sensor values and center around zero
    // Did not convert to engineering units, since will experiment to find P gain anyway
    for (axis = ROLL; axis < LASTAXIS; axis++) {
      gyroADC[axis] = (gyroInvert[axis] ? (1024 - analogRead(gyroChannel[axis])) : analogRead(gyroChannel[axis]))  - gyroZero[axis];
      accelADC[axis] = (accelInvert[axis] ? (1024 - analogRead(accelChannel[axis])) : analogRead(accelChannel[axis])) - accelZero[axis];
    }
    // Compiler seems to like calculating this in separate loop better
    for (axis = ROLL; axis < LASTAXIS; axis++) {
      gyroData[axis] = smooth(gyroADC[axis], gyroData[axis], smoothFactor[GYRO]);
      accelData[axis] = smooth(accelADC[axis], accelData[axis], smoothFactor[ACCEL]);
    }

    // ****************** Calculate Absolute Angle *****************
    //dt = deltaTime / 1000.0; // Convert to seconds from milliseconds for complementary filter
    //filterData(previousAngle, gyroADC, angle, *filterTerm, dt)
    flightAngle[ROLL] = filterData(flightAngle[ROLL], gyroADC[ROLL], atan2(accelADC[ROLL], accelADC[ZAXIS]), filterTermRoll, AIdT);
    flightAngle[PITCH] = filterData(flightAngle[PITCH], gyroADC[PITCH], atan2(accelADC[PITCH], accelADC[ZAXIS]), filterTermPitch, AIdT);
    //flightAngle[ROLL] = filterData(flightAngle[ROLL], gyroData[ROLL], atan2(accelData[ROLL], accelData[ZAXIS]), filterTermRoll, dt);
    //flightAngle[PITCH] = filterData(flightAngle[PITCH], gyroData[PITCH], atan2(accelData[PITCH], accelData[ZAXIS]), filterTermPitch, dt);
    analogInputTime = currentTime;
  } 
//////////////////////////////
// End of analog input loop //
//////////////////////////////

// ********************************************************************
  // *********************** Flight Control Loop ************************
// ********************************************************************
  if ((currentTime > controlLoopTime + CONTROLLOOPTIME) && (controlLoop == ON)) { // 500Hz

  // ********************* Check Flight Mode *********************
    #ifdef AutoLevel
      if (transmitterCommandSmooth[MODE] < 1500) {
        // Acrobatic Mode
    levelAdjust[ROLL] = 0;
    levelAdjust[PITCH] = 0;
      }
      else {
        // Stable Mode
      for (axis = ROLL; axis < YAW; axis++)
          levelAdjust[axis] = limitRange(updatePID(0, flightAngle[axis], &PID[LEVELROLL + axis]), -levelLimit, levelLimit);
      // Turn off Stable Mode if transmitter stick applied
        if ((abs(receiverData[ROLL] - transmitterCenter[ROLL]) > levelOff)) {
          levelAdjust[ROLL] = 0;
          PID[axis].integratedError = 0;
        }
        if ((abs(receiverData[PITCH] - transmitterCenter[PITCH]) > levelOff)) {
          levelAdjust[PITCH] = 0;
          PID[PITCH].integratedError = 0;
        }
        if (abs(flightAngle[ROLL] < 0.25)) PID[ROLL].integratedError = 0;
        if (abs(flightAngle[PITCH] < 0.25)) PID[PITCH].integratedError = 0;
      }      
      #endif
      
    // ************************** Update Roll/Pitch ***********************
    motorAxisCommand[ROLL] = updatePID(transmitterCommand[ROLL], (gyroData[ROLL] * mMotorRate) + bMotorRate, &PID[ROLL]) + levelAdjust[ROLL];
    motorAxisCommand[PITCH] = updatePID(transmitterCommand[PITCH], (gyroData[PITCH] * mMotorRate) + bMotorRate, &PID[PITCH]) - levelAdjust[PITCH];
      
    // ***************************** Update Yaw ***************************
    // Note: gyro tends to drift over time, this will be better implemented when determining heading with magnetometer
    // Current method of calculating heading with gyro does not give an absolute heading, but rather is just used relatively to get a number to lock heading when no yaw input applied
      #ifdef HeadingHold
      currentHeading += gyroData[YAW] * headingScaleFactor * controldT;
      if (transmitterCommand[THROTTLE] > MINCHECK ) { // apply heading hold only when throttle high enough to start flight
        if ((transmitterCommand[YAW] > (MIDCOMMAND + 25)) || (transmitterCommand[YAW] < (MIDCOMMAND - 25))) { // if commanding yaw, turn off heading hold
          headingHold = 0;
          heading = currentHeading;
        }
        else // no yaw input, calculate current heading vs. desired heading heading hold
          headingHold = updatePID(heading, currentHeading, &PID[HEADING]);
        }
      else {
        heading = 0;
        currentHeading = 0;
        headingHold = 0;
        PID[HEADING].integratedError = 0;
      }
      motorAxisCommand[YAW] = updatePID(transmitterCommand[YAW] + headingHold, (gyroData[YAW] * mMotorRate) + bMotorRate, &PID[YAW]);
      #endif
  
    #ifndef HeadingHold
    motorAxisCommand[YAW] = updatePID(transmitterCommand[YAW], (gyroData[YAW] * mMotorRate) + bMotorRate, &PID[YAW]);
    #endif
    
    // ****************** Calculate Motor Commands *****************
    if (armed && safetyCheck) {
      #ifdef plusConfig
        motorCommand[FRONT] = limitRange(transmitterCommand[THROTTLE] - motorAxisCommand[PITCH] - motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[REAR] = limitRange(transmitterCommand[THROTTLE] + motorAxisCommand[PITCH] - motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[RIGHT] = limitRange(transmitterCommand[THROTTLE] - motorAxisCommand[ROLL] + motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[LEFT] = limitRange(transmitterCommand[THROTTLE] + motorAxisCommand[ROLL] + motorAxisCommand[YAW], minCommand, MAXCOMMAND);
      #endif
      #ifdef XConfig
        // Front = Front/Right, Back = Left/Rear, Left = Front/Left, Right = Right/Rear 
        motorCommand[FRONT] = limitRange(transmitterCommand[THROTTLE] - motorAxisCommand[PITCH] + motorAxisCommand[ROLL] - motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[RIGHT] = limitRange(transmitterCommand[THROTTLE] - motorAxisCommand[PITCH] - motorAxisCommand[ROLL] + motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[LEFT] = limitRange(transmitterCommand[THROTTLE] + motorAxisCommand[PITCH] + motorAxisCommand[ROLL] + motorAxisCommand[YAW], minCommand, MAXCOMMAND);
        motorCommand[REAR] = limitRange(transmitterCommand[THROTTLE] + motorAxisCommand[PITCH] - motorAxisCommand[ROLL] - motorAxisCommand[YAW], minCommand, MAXCOMMAND);
      #endif
    }
  
    // If throttle in minimum position, don't apply yaw
    if (transmitterCommand[THROTTLE] < MINCHECK) {
      for (motor = FRONT; motor < LASTMOTOR; motor++)
        motorCommand[motor] = minCommand;
    }
    // If motor output disarmed, force motor output to minimum
    if (armed == 0) {
      switch (calibrateESC) { // used for calibrating ESC's
      case 1:
        for (motor = FRONT; motor < LASTMOTOR; motor++)
          motorCommand[motor] = MAXCOMMAND;
        break;
      case 3:
        for (motor = FRONT; motor < LASTMOTOR; motor++)
          motorCommand[motor] = limitRange(testCommand, 1000, 1200);
        break;
      case 5:
        for (motor = FRONT; motor < LASTMOTOR; motor++)
          motorCommand[motor] = limitRange(remoteCommand[motor], 1000, 1200);
        safetyCheck = 1;
        break;
      default:
        for (motor = FRONT; motor < LASTMOTOR; motor++)
          motorCommand[motor] = MINCOMMAND;
      }
    }

    // *********************** Command Motors **********************
    commandMotors();
    controlLoopTime = currentTime;
  } 
/////////////////////////
// End of control loop //
/////////////////////////

  serialcoms.process(currentTime);  
  gps.process(currentTime);
  blinkie.process(currentTime);
  
// *************************************************************
// ******************* Camera Stailization *********************
// *************************************************************
#ifdef Camera // Development moved to Arduino Mega
  if ((currentTime > (cameraTime + CAMERALOOPTIME)) && (cameraLoop == ON)) { // 50Hz
    rollCamera.write((mCamera * flightAngle[ROLL]) + bCamera);
    pitchCamera.write(-(mCamera * flightAngle[PITCH]) + bCamera);
    cameraTime = currentTime;
  }
#endif
////////////////////////
// End of camera loop //
////////////////////////
}