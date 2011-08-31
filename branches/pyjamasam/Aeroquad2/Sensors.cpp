#include <WProgram.h>

#include <APM_ADC.h>
#include <Wire.h>

#include "Sensors.h"

#include "SerialComs.h"

PowerSensor::PowerSensor() : AnalogInHardwareComponent(2)
{
	
}

void PowerSensor::initialize()
{
	AnalogInHardwareComponent::initialize();
}	
		
void PowerSensor::process(const unsigned long currentTime)
{
	AnalogInHardwareComponent::process(currentTime);
}



PressureSensor::PressureSensor() : HardwareComponent()
{
	_currentPressure = 0.0f;
	_currentTemperature = 0.0f;
}

void PressureSensor::initialize()
{
	HardwareComponent::initialize();
}	

void PressureSensor::process(const unsigned long currentTime)
{						
	HardwareComponent::process(currentTime);	
}

const long PressureSensor::temperature()
{
	return _currentTemperature;
}

const long PressureSensor::pressure()
{
		return _currentPressure;
}

const float PressureSensor::altitude()
{
	float tmp_float = (_currentPressure/101325.0);
	tmp_float = pow(tmp_float,0.190295);
	return 44330.0*(1.0-tmp_float);    
}


//Based on the code from: http://code.google.com/p/arducopter/source/browse/trunk/libraries/APM_BMP085/APM_BMP085.cpp and http://code.jeelabs.org/libraries/Ports/PortsBMP085.cpp
//Because of the way this sensor is coded it responds at 1/2 of the sensor subsystem cycle speed
#define BMP085_ADDRESS 0x77  //(0xEE >> 1)
#define BMP085_EOC_PIN 30        // End of conversion pin PC7

		
void BMP085PressureSensor::_initiateRawTemperatureReading()
{
	Wire.beginTransmission(BMP085_ADDRESS);
	Wire.send(0xF4);
	Wire.send(0x2E);
	Wire.endTransmission();
}

const long BMP085PressureSensor::_readRawTempature()
{
	byte msb, lsb;
	
	Wire.beginTransmission(BMP085_ADDRESS);
		Wire.send(0xF6);
	Wire.endTransmission();	
	
	Wire.requestFrom(BMP085_ADDRESS,2);
	{
		while(!Wire.available());		// waiting			
		msb = Wire.receive();
	
		while(!Wire.available());		// waiting
		lsb = Wire.receive();
	}
	Wire.endTransmission();
				
	return (long)msb << 8 | (long)lsb;
}				

void BMP085PressureSensor::_initiateRawPressureReading()
{
	Wire.beginTransmission(BMP085_ADDRESS);
		Wire.send(0xF4);
		Wire.send(0x34+(_samplingMode<<6));
	Wire.endTransmission();
}

const int32_t BMP085PressureSensor::_readRawPressure()
{
	byte msb, lsb, xlsb;
	
	Wire.beginTransmission(BMP085_ADDRESS);
	Wire.send(0xF6);
	Wire.endTransmission();
	
	Wire.requestFrom(BMP085_ADDRESS, 3);
	{
		while(!Wire.available());		// waiting			
		msb = Wire.receive();
	
		while(!Wire.available());		// waiting
		lsb = Wire.receive();
	
		while(!Wire.available());		// waiting
		xlsb = Wire.receive();
	}
	Wire.endTransmission();
	
	return (((long)msb<<16) | ((long)lsb<<8) | ((long)xlsb)) >> (8-_samplingMode);
}

void BMP085PressureSensor::_processReadings()
{
	//Based on the code from page 13 of the datasheet														
	int32_t x1, x2, x3, b3, b5, b6, p;
    uint32_t b4, b7;

    x1 = (_rawTemperature - _calibrationAC6) * _calibrationAC5 >> 15;
    x2 = ((int32_t) _calibrationMC << 11) / (x1 + _calibrationMD);
    b5 = x1 + x2;
    _currentTemperature = (b5 + 8) >> 4;
    
    b6 = b5 - 4000;
    x1 = (_calibrationB2 * (b6 * b6 >> 12)) >> 11; 
    x2 = _calibrationAC2 * b6 >> 11;
    x3 = x1 + x2;
    b3 = ((((int32_t) _calibrationAC1 * 4 + x3) << _samplingMode) + 2) >> 2;
    x1 = _calibrationAC3 * b6 >> 13;
    x2 = (_calibrationB1 * (b6 * b6 >> 12)) >> 16;
    x3 = ((x1 + x2) + 2) >> 2;
    b4 = (_calibrationAC4 * (uint32_t) (x3 + 32768)) >> 15;
    b7 = ((uint32_t) _rawPressure - b3) * (50000 >> _samplingMode);
    p = b7 < 0x80000000 ? (b7 * 2) / b4 : (b7 / b4) * 2;
    
    x1 = (p >> 8) * (p >> 8);
    x1 = (x1 * 3038) >> 16;
    x2 = (-7357 * p) >> 16;
    _currentPressure = p + ((x1 + x2 + 3791) >> 4);
}
	


BMP085PressureSensor::BMP085PressureSensor() : PressureSensor()
{
	_samplingMode = 3;				//Over Sampling
	_state = 0;
	
	_rawTemperature = 0;
	_rawPressure = 0;			
}

void BMP085PressureSensor::initialize()
{
	PressureSensor::initialize();		
	
	pinMode(BMP085_EOC_PIN,INPUT);   // End Of Conversion (PC7) input
	
	Wire.begin();
	
	//Read the calibration registers
	Wire.beginTransmission(BMP085_ADDRESS);
	Wire.send(0xAA);
	Wire.endTransmission();
	
	byte rawCalibrationData[22];
	Wire.requestFrom(BMP085_ADDRESS, 22);  
	int i = 0;
	while(Wire.available())
	{ 
		rawCalibrationData[i] = Wire.receive();  // receive one byte
		i++;
	}
		
	_calibrationAC1 = ((int)rawCalibrationData[0] << 8) | rawCalibrationData[1];
	_calibrationAC2 = ((int)rawCalibrationData[2] << 8) | rawCalibrationData[3];
	_calibrationAC3 = ((int)rawCalibrationData[4] << 8) | rawCalibrationData[5];
	_calibrationAC4 = ((int)rawCalibrationData[6] << 8) | rawCalibrationData[7];
	_calibrationAC5 = ((int)rawCalibrationData[8] << 8) | rawCalibrationData[9];
	_calibrationAC6 = ((int)rawCalibrationData[10] << 8) | rawCalibrationData[11];
	_calibrationB1 = ((int)rawCalibrationData[12] << 8) | rawCalibrationData[13];
	_calibrationB2 = ((int)rawCalibrationData[14] << 8) | rawCalibrationData[15];
	_calibrationMB = ((int)rawCalibrationData[16] << 8) | rawCalibrationData[17];
	_calibrationMC = ((int)rawCalibrationData[18] << 8) | rawCalibrationData[19];
	_calibrationMD = ((int)rawCalibrationData[20] << 8) | rawCalibrationData[21];						

	//Wire.endTransmission();	
	
	//setup for the first step
	_state = 0;
	_initiateRawTemperatureReading();
}

void BMP085PressureSensor::process(unsigned long currentTime)
{
	PressureSensor::process(currentTime);			
	
	switch (_state)
	{
		case 0:
		{
			//Attempt to read the temperature reading this time through the loop
			if (digitalRead(BMP085_EOC_PIN))
			{				
				_rawTemperature = _readRawTempature();
			
				//setup for the next step through
				_initiateRawPressureReading();
				_state++;
			}
			break;	
		}
		case 1:
		{					
			//Attempt to read the pressure reading this time through the loop
			
			//If the end of conversion pin is high proceed with the reading
			if (digitalRead(BMP085_EOC_PIN))
			{
				_rawPressure = _readRawPressure();
				
				//process true tempature and pressure readings						
				_processReadings();												
				
				//Back to the first step
				_state = 0;
				_initiateRawTemperatureReading();
			}
			break;	
		}				
	}
}
			


/*#define BARO_CSB 47
#define BARO_DRDY 46
#define PRESSURE_MSB_REGISTER 0x1F   //Pressure 3 MSB
#define PRESSURE_LSB_REGISTER 0x20   //Pressure 16 LSB

class SPIPressureSensor : public PressureSensor, SPIDevice
{		
	private:
	
		const byte readByteFromRegister(const byte registerAddress)
		{
		    byte adjustedRegisterAddress = registerAddress << 2;
		    adjustedRegisterAddress &= B11111100; //Read command

			this->activate();			
		    this->sendByte(adjustedRegisterAddress);
			byte returnByte = this->readByte();	
			this->deactivate();
			
			return returnByte;
		}
		
		const int readIntFromRegister(const byte registerAddress)
		{
		    byte adjustedRegisterAddress = registerAddress << 2;
		    adjustedRegisterAddress &= B11111100; //Read command

			this->activate();	
		    this->sendByte(adjustedRegisterAddress);
		    byte in_byte1 = this->readByte();	  
		    byte in_byte2 = this->readByte();
			this->deactivate();		
		
			return (((in_byte1) << 8) | (in_byte2));
		}
		
		const byte sendByteToRegister(const byte registerAddress, const byte registerValue)
		{
		    byte adjustedRegisterAddress = registerAddress << 2;
		    adjustedRegisterAddress |= B00000010; //Write command

			this->activate();			
		    this->sendByte(adjustedRegisterAddress);
			byte returnByte = this->sendByte(registerValue);	
			this->deactivate();
			
			return returnByte;
		}
	
	public:		
		void initialize()
		{
			PressureSensor::initialize();
			SPIDevice::initialize(BARO_CSB);
			
			pinMode(BARO_DRDY, INPUT);
			
			this->sendByteToRegister(0x03, 0x0A);
		}
		
		void process(const unsigned long currentTime)
		{	
			unsigned long pressureMsb = this->readByteFromRegister(PRESSURE_MSB_REGISTER);
		  	pressureMsb &= B00000111;
	
		  	unsigned long pressureLsb = this->readIntFromRegister(PRESSURE_LSB_REGISTER);
				  
			_currentPressure = (((pressureMsb) << 16) | (pressureLsb));
		  	_currentPressure /= 4;
		
			PressureSensor::process(currentTime);
		}
};
*/

HeightSensor::HeightSensor() : AnalogInHardwareComponent(1)
{
	
}

void HeightSensor::initialize()
{
	AnalogInHardwareComponent::initialize();
}	

void HeightSensor::process(const unsigned long currentTime)
{
	AnalogInHardwareComponent::process(currentTime);	
}

const float HeightSensor::height()
{
	return _lastReadings[0];
}


#define HEIGHTSENSOR_INPUTPIN 10	
MaxbotixSonarHeightSensor::MaxbotixSonarHeightSensor() : HeightSensor()
{
	this->setReferenceVoltage(3300);
	this->setAdcPrecision(12);
}

void MaxbotixSonarHeightSensor::initialize()
{
	HeightSensor::initialize();
	
	_inputConfigurations[0].zeroLevel = 0;						//mv
	_inputConfigurations[0].sensitivity = 384.473425;		//mv/m	(9.765625; 			//mv/in)
	_inputConfigurations[0].inputInUse = true; 
	_inputConfigurations[0].hardwarePin = 7;
}

const int MaxbotixSonarHeightSensor::readRawValue(const unsigned int channel)
{
	return APM_ADC.Ch(channel);
}


Sensors::Sensors() : SubSystem()
{				
}

void Sensors::initialize(const unsigned int frequency, const unsigned int offset) 
{ 
	SubSystem::initialize(frequency, offset);
							
	if (_pressureSensor)
	{
		_pressureSensor->initialize();
	}
	
	if (_powerSensor)
	{
		_powerSensor->initialize();
	}
				
	if (_heightSensor)
	{
		_heightSensor->initialize();
	}
	
	serialcoms.shell()->registerKeyword("monitorSensors", "monitorSensors", _monitorSensors , true);
}

void Sensors::process(const unsigned long currentTime)
{
	if (this->_canProcess(currentTime))
	{				
		SubSystem::recordProcessingStartTime();
		
		if (_pressureSensor)
		{
			_pressureSensor->process(currentTime);
		}
		
		if (_powerSensor)
		{
			_powerSensor->process(currentTime);
		}
						
		if (_heightSensor)
		{
			_heightSensor->process(currentTime);
		}
		
		SubSystem::recordProcessingEndTime();
	}
}

void Sensors::setPressorSensorType(const PressureSensorType hardwareType)
{
	switch (hardwareType)
	{
		case PressureSensorBMP085:
		{
			_pressureSensor = new BMP085PressureSensor();
			break;
		}
		
		default:
		{
			serialcoms.println("ERROR: Unknown Pressure Sensor type selected.");					
			break;
		}
	}
}

void Sensors::setPowerSensorType(const PowerSensorType hardwareType)
{
	switch (hardwareType)
	{
		/*case PressureSensorSPI:
		{
			//_pressureSensor = new SPIPressureSensor();
			break;
		}*/
		
		default:
		{
			serialcoms.println("ERROR: Unknown Power Sensor type selected.");					
			break;
		}
	}
}

void Sensors::setHeightSensorType(const HeightSensorType hardwareType)
{
	switch (hardwareType)
	{
		case MaxbotixSonar:
		{
			_heightSensor = new MaxbotixSonarHeightSensor();
			break;
		}
		
		default:
		{
			serialcoms.println("ERROR: Unknown Height Sensor type selected.");					
			break;
		}
	}
}
		
//accessors for sensor values
const long Sensors::temperature()
{
	if (_pressureSensor)
	{
		return _pressureSensor->temperature();
	}
	
	return 0.0f;
}

const long Sensors::pressure()
{
	if (_pressureSensor)
	{
		return _pressureSensor->pressure();
	}
	
	return 0.0f;
}

const float Sensors::altitudeUsingPressure()
{
	if (_pressureSensor)
	{
		return _pressureSensor->altitude();
	}
	
	return 0.0f;
}

const float Sensors::altitudeUsingHeightSensor()
{
	if (_heightSensor)
	{
		return _heightSensor->height();
	}
	
	return 0.0f;
}	

Sensors sensors;

const ArduinoShellCallback::callbackReturn _monitorSensors(ArduinoShell &shell, const int argc, const char* argv[])
{
	shell << sensors.temperature() << ","
			<< sensors.pressure() << ","
			<< sensors.altitudeUsingPressure() << ","
			<< sensors.altitudeUsingHeightSensor() 	<<endl;

	return ArduinoShellCallback::Success;			
}