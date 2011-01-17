// Heart Spark V1.0
// Copyright 2010 Sensebridge.net
// Released under cc-sa-nc

#define DS1307_I2C_ADDRESS  B1101000
#define EEPROM_I2C_ADDRESS  B1010000
#define PCF8563_I2C_ADDRESS B1010001

#include <avr/sleep.h>
#include <avr/power.h>
#include <Wire.h>
#include <MsTimer2.h>  // http://www.arduino.cc/playground/Main/MsTimer2

// version number
const char* HSversion = "020";

// numbering from the top left around clockwise!
byte LED6 = 3;
byte LED4 = 5;
byte LED5 = 6;
byte LED1 = 9;
byte LED2 = 10;
byte LED3 = 11;

byte EEPROM_WP = 4;  // Write Protect pin on D4.  Set LOW to enable writing
byte POLARout = 2;   //D2 is also interrupt "0"

byte DIP1pin = 8;
byte DIP2pin = 7;

int i = 0;
int j = 0;
byte Mode = 0;  // 0=startup, 1=polar, 2=fake
byte Chatter = 1;  // it's OK to put random crap out on serial
byte IsLoggingVersion = 1; // does this version even have RTC and EEPROM?
byte Logging = 1 & IsLoggingVersion;  // it's OK to log to EEPROM
    // & IsLoggingVersion: so that you don't forget to turn off this variable 
    // too: it's impossible to be logging if it's not a logging version!
boolean TroubleReadingHeader = false;

// values modified inside the interrupt function
// must be declared as volatile
volatile boolean PolarIRQ = false;

unsigned int PolarTime;
unsigned int HeartRate = 0;
byte setblink = 0;
byte NoSecondSkip = 0;

unsigned long LastTime = 0;
unsigned long InitTime = 0;
unsigned int eecounter = 1;
unsigned int readcounter = 1;
unsigned int MinuteCount = 0;
unsigned int LastMinute = 0;
unsigned int BlinkCount = 0;
byte SleepBlinkStep = 0;

byte second;        // 0-59
byte minute;	  // 0-59
byte hour;	    // 0-23
byte dayOfWeek;     // 1-7
byte dayOfMonth;    // 1-28/29/30/31
byte month;	   // 1-12
byte year;	    // 0-99

byte DIPs = 0;

byte ToSend[128];
byte ToSendIndex = 0;


void setup() {
  Serial.begin(57600);          //  setup serial
  if (Chatter) Serial.println("setup");

  // there are two pins on the ATMEGA that are shorted
  // to other traces, because of routing convenience
  // got to make sure those are high impedance inputs with no pullup...  
  pinMode(A7, INPUT);
  pinMode(A0, INPUT);
  digitalWrite(A7, LOW);
  digitalWrite(A0, LOW);

  pinMode(LED1, OUTPUT);
  pinMode(LED2, OUTPUT);
  pinMode(LED3, OUTPUT);
  pinMode(LED4, OUTPUT);
  pinMode(LED5, OUTPUT);
  pinMode(LED6, OUTPUT);

  pinMode(EEPROM_WP, OUTPUT);
  digitalWrite(EEPROM_WP, LOW);  // do not write protect
  
  pinMode(POLARout, INPUT);
  
  pinMode(DIP1pin, INPUT);
  pinMode(DIP2pin, INPUT);
  digitalWrite(DIP1pin, HIGH);  // set internal pullup resistor on
  digitalWrite(DIP2pin, HIGH);  // set internal pullup resistor on
  
  Wire.begin();
      
  // we do this later now, to avoid spurious false-positives  
  //attachInterrupt(0, PolarInterrupt, RISING);

  // TWO options here:
  // 1) SLEEP_MODE_PWR_DOWN = near total shutdown, saves most power
  //       and thus provides longer battery life, but also kills
  //       all timer functions, so you can't collect millisecond
  //       heart rate timing data
  //set_sleep_mode(SLEEP_MODE_PWR_DOWN);

  // 2) SLEEP_MODE_IDLE + power_*_disable, consumes about 3x the power
  //       of the above, but still allows the millisecond timers to
  //       work, so that you can collect timing data
  set_sleep_mode(SLEEP_MODE_IDLE);  // leaves the clock & timer2 running
  power_adc_disable();
  power_spi_disable();
  //power_timer0_disable();  // leave this ENABLED, it does millis()!
  power_timer1_disable();
  power_timer2_enable();  // this handles fake mode, make sure it's enabled
      // NOTE: all three timers are used for PWM pins
  if (IsLoggingVersion)
    power_twi_enable();   // leave this ENABLED, it talks to EEPROM/RTC
  else
    power_twi_disable();
  // set clock prescaler to 8, resulting in 1MHz operation.
  // saves about 2mA of standby power
  // NOTE: this messes with all timer functions, like delay()
  //    you need to divide by 8 to get the same amount of delay
  //CLKPR = (1<<CLKPCE);
  //CLKPR = B00000011; 
  
  sleep_enable();          // enables the sleep bit in the mcucr register
                           // so sleep is possible. just a safety pin
                           
  DIP_mode();  // check before we sleep if we're in fake mode!
  InitTime = millis();
  Startup_Blink();

  // do this last, give the EEPROM time to start itself, esp. in cases
  // of brownout
  if (Logging) ReadParseHeader(); // set EEPROM page counter to first unwritten page
}



/* ***************************************************** */
/* ******************** MAIN LOOP ********************** */
/* ***************************************************** */
/* This program is almost entirely interrupt driven, that
makes it harder to understand.  Basically, we wait for pulses
from the polar reciever.  They trigger PolarInterrupt().
It gathers some data, and then sets "setblink".  We fall
out of the interrupt and back into loop(), which sees
setblink(), logs the data, and sets SleepBlinkStep.
blink_leds_lowpower triggers on SleepBlinkStep, and
causes the LEDs to flash, but does so keeping the ATMEGA
asleep almost all of the time.  Lather rinse repeat.

During "normal" operation, the device is waking once/ms,
because of the MsTimer2 library.  So anything in loop() is
hit once/ms, which is why everything is behind if statements,
so that the main loop can put things back to sleep quickly.

If the DIPs position is "fake mode", then timer2 is used to 
wake up the device at 75 BPM and blink the LEDs, while
any interrupts from the polar are simply ignored.
/* **************************************************** */
void loop() {
  
  attachInterrupt(0, PolarInterrupt, RISING);
  sleep_mode();
  detachInterrupt(0);
  
  if (PolarIRQ)
  {
    PolarIRQ = false;
    PolarCalcs();
  }

  // check DIPs always, because otherwise you can end up not 
  // trigger fakemode when they are not wearing a chest strap
  // and the flip the switches after they power up...  
  DIP_mode();
  
  if (setblink)
  {
    setblink = 0;
    
    if (DIPs == 0)
      fancy2_blink();
    else if (DIPs == 1)
      activity_blink();
    else if (DIPs == 2)
      blink_leds();
    else // DIPs == 3, also catch all
      fake_blink();
    
    
    if (Mode != 2)
    {  // only log if it's REAL data, duh!
      BlinkCount++;
      // log only if requested, and only until we've used up all 512 pages
      if (Logging && (eecounter < 512)) CollectData();
    }

  }

  // this is massively elaborate, and requires timer2 to be on to work
  // so for now I'm not using it.
  //blink_leds_lowpower();

  if (Serial.available()) // we've got a message from the software
    HandleSerial();
}


void HandleSerial()
{
  char input = ' ';
  input = Serial.read();
  
  if (input == 'v')   // send firmware version number
    Serial.println(HSversion);
  else if (input == 'c')   // toggle chatter mode
    ToggleChatter();

  if (IsLoggingVersion)
  {
    if (input == '*')  // send a data line from eeprom
      ReadPrintDataLine();
    else if (input == 'r')   // reset read counter to first data page
      readcounter = 1;
    else if (input == 'd')   // read RTC and print
      PrintDate();
    else if (input == 'D')   // set date based on forthcoming date string
      GetSetDate();
    else if (input == 'l')   // toggle logging
      ToggleLogging();
    else if (input == 'p')   // send current page number
      Serial.println(eecounter); // no if (Chatter), need this info!
    else if (input == 'P')   // RESET page number to 1 (note: this will overwrite old data!)
      ResetEECounter();
    else if (input == 't')   // test the EEPROM
      TestEEPROM();
  }
}


void SetupFakeMode()
{
  if (Chatter) Serial.println("Starting Fake Mode!");
  power_timer2_enable();  // this handles fake mode, but disable till we need it
  //power_twi_disable(); // turn off the TWI, we don't need it in fake mode
  ModeChangeFlash();
  Mode = 2;  // set mode to "fake", prevents blinks on real interrupts
  BlinkCount = 0;
  MsTimer2::set(800, StartFakeBlink);  // make it fake a blink at 75 BMP
  MsTimer2::start();
}

void EndFakeMode()
{
  MsTimer2::stop();
  //if (Logging) power_twi_enable(); // turn on TWI if logging in real mode
  if (Chatter) Serial.println("Stopping Fake Mode!");
  ModeChangeFlash();
  InitTime = millis();
  Mode = 0;  // go back to "start", see if we in fact do have real signal
  BlinkCount = 0;
}

void StartFakeBlink()
{  // this is an interrupt called function
  HeartRate = 75;  // this gets messed with if there are real signals
      // but we don't want to show it, because they are usually false postivies...
  setblink = 1;
}

void ResetEECounter()
{
  eecounter = 1;    // reset page to first non-header page
  ToSendIndex = 0;  // reset current data set to "empty"
  // and, write this reset to the header page to make it "official"
  WriteHeaderPage();
}


void ToggleLogging()
{
  Logging = 1-Logging;

  if (Logging)
    power_twi_enable();
  else
    power_twi_disable();  // save power if we don't need it

  if (Chatter)
  {
    Serial.print("Logging: ");
    Serial.println(Logging, DEC);
  }  
}

void ToggleChatter()
{
  Chatter = 1-Chatter;
  
  //{
    Serial.print("Chatter: ");
    Serial.println(Chatter, DEC);
  //}
}

void PrintDate()
{  // print in csv format for easy parsing
   //getDateDs1307();   
   getDate8536();
   /*
   Serial.print(hour, DEC);
   Serial.print(":");
   Serial.print(minute, DEC);
   Serial.print(":");
   Serial.print(second, DEC);
   Serial.print(" ");
   Serial.print(year+2000, DEC);
   Serial.print("-");
   Serial.print(month, DEC);
   Serial.print("-");
   Serial.print(dayOfMonth, DEC);
   Serial.println("");
   */
   
   Serial.print("001,"); // format version
       // actually this is here just so that the date will be in the 
       // same set of buffers ([1]->[6]) as it always is
   Serial.print(year, DEC);
   Serial.print(",");
   Serial.print(month, DEC);
   Serial.print(",");
   Serial.print(dayOfMonth, DEC);
   Serial.print(",");
   Serial.print(hour, DEC);
   Serial.print(",");
   Serial.print(minute, DEC);
   Serial.print(",");
   Serial.print(second, DEC);
   Serial.println(",");
   
}

void ReadParseHeader()
{
  // grab the header, and set the eecounter to the first empty position
 i2c_eeprom_read_buffer(EEPROM_I2C_ADDRESS, 0, &ToSend[0], 32);
 if (ToSend[0] == 201)
 {  // then we've got a valid header
   eecounter = ToSend[7];  // page count
   ToSendIndex = 0; //ToSend[8]; // byte count inside page
     // always make it zero for now, we must regenerate the page from
     // scratch since we're not doing partial logging of the page...
   // maybe do something with that date, too?
   if (Chatter)
   {
     Serial.print("Starting logging at EEPROM page number: ");
     Serial.println(eecounter);
   }
 }
 else
 { // well now, we've got some kind of error or strange thing going on
   // I have experienced cases where the HS will repeatidly overwrite 
   // the start of the EEPROM when the battery voltage gets low
   // I think this is because the ATMEGA resets, and when we get to
   // here, the EEPROM header pages fails to read correctly (perhaps
   // because the EEPROM too is suffering from low voltage problem)
   // giving us a chance: give the battery TIME to get back to a reasonable
   // voltage.  I know it can, since the device will operate for at least
   // 4 hours past the first brown-out according to my data
   // the trick is to SLEEP, giving the battery time to recover
   // so: disable polar interrupt, trigger timer interrupt for a few seconds
   // from now, and sleep.  When it wakes, read the page, then resume normal
   // operation.
   if (TroubleReadingHeader == false)  // check if first time through this trouble
   {
      TroubleReadingHeader = true;
      detachInterrupt(0);
      Logging = false;  // make sure we don't overwrite page one or the header
      MsTimer2::set(2000, DelayedHeaderRead);
      MsTimer2::start();
      sleep_mode();  // knock ourselves out for 2 seconds
   }
   else
   {  // we're failed to read a proper header TWICE now
      // after much thought, I've decided that the best bet here is to 
      // simply DIE.  Any other behavior risks overwriting good data.
      // BUT, it should be noted that the case of corrupt header data is
      // probably as likely as the case of brown-out failure-to-read. It's
      // just that both cases have the SAME best course of action: get the
      // user to DO something, like replace the battery or grab the data
      // and reset the header page.  So, blink "error blink" and sleep
      // permanently at lowest power mode.
      // another good reason to knock ourselves out in this case is
      // to preserve power for the RTC, so that if they notice
      // a few hours from now, the time will still be correct!
     Error_Blink();
     detachInterrupt(0);
     MsTimer2::stop();
     set_sleep_mode(SLEEP_MODE_PWR_DOWN);  // everything off
     sleep_mode();  // we will never wake from this
   }
 }
   
}

void DelayedHeaderRead()
{  // try again, see if we get lucky
  MsTimer2::stop();
  ReadParseHeader();
}

void ReadPrintDataLine()
{
  for (i = 0; i<4; i++)
  {
    i2c_eeprom_read_buffer(EEPROM_I2C_ADDRESS, readcounter*128+i*32, &ToSend[i*32], 32);
    delay(4);
  }
  PrintBuffer();
  readcounter++;
}


void TestEEPROM()
{ // simple function to write some data to the eeprom and read it back,
  // thus confirming that the eeprom is working...
  
  for (i = 0; i<32; i++)
  {
    ToSend[i] = j;
    j++;
    if (j > 255) j = 0;
  }
  
  // write into the header page, but above where the useful data is
  // usually stored.  Note that the header page is the most likely
  // page to fail, since we write it *way* more than any other page.
  i2c_eeprom_write_page(EEPROM_I2C_ADDRESS, 32,ToSend, 32);
  delay(4);

  for (i = 0; i<32; i++)
    ToSend[i] = 0;
  
  i2c_eeprom_read_buffer(EEPROM_I2C_ADDRESS, 32, ToSend, 32);
  PrintBuffer();
}

void DIP_mode()
{
  // check DIPs, then switch mode
  DIPs = digitalRead(DIP1pin);
  DIPs += 2 * digitalRead(DIP2pin);
  if (Chatter)
  {
    Serial.print("DIPs: ");
    Serial.println(DIPs, DEC);
  }
  
  if ( (DIPs == 3) && (Mode != 2))
  {  // then the user just switched to fake mode 
    SetupFakeMode();
  }
  else if ( (Mode == 2) && (DIPs != 3) )
  {  // then the user just switched away from fake mode
    EndFakeMode();
  }
}

void CollectData()
{

/*
Some notes on my testing of Wire.h library and EEPROM code:
 - addresses are to bytes: the 512kbit EEPRMOM has 64k bytes, which 
      is perfectly addressed by unsigned 16-bit int
 - EEPROM itself is structed into 128-byte PAGES
    - if you try to WRITE past a page end, the write loops and
        overwrites the beginning of the current page (bad!!)
    - if you try to READ past a page end, you'll receive 0's
 - the EEPROM has limited write-cycles, it specifies 1,000,000 writes,
     for each page.  Furthermore, writing a page takes ~3.5ms, during which
     time the EEPROM will SEEM to accept commands, but actualy spit back
     garbage and certainly NOT write...
 - Wire.h is terribly written.  It actually uses *5* buffers, each of size
     BUFFER_SIZE = 32.  So you can only send 32 byte messages using Wire.h
     Further more, there is some kind of bug, write actually fucks up the 
     31st & 32nd byte, so the actual usable write buffer size is only 30 bytes
 - combining the previous facts, you can immediatly see a problem
    - addressing data in 30-byte chunks, you'd have to be super paranoid
       about page boundaries, and likely end up not using some of the memory
 - my solution: for now, do everything in 128-byte arrays, and just
    write a wrapper for Wire.h that writes 128 bytes in 5 chunks to put 
    the whole page down.  This will obviously go through the eeprom's 
    limited write cycles 5x as fast as actually writing out the 128-byte 
    pages in one go, but it will still be way better than managing page 
    boundaries, and I'll rewrite Wire.h at some later point to fix this issue.

Heart Spark EEPROM Data Format
------------------------------

Each 128-byte PAGE has it's own internal map and structure, according to 
it's type:

Byte 0: page type
  101: BPM page, 0-255 BPM (a byte of data) for each heart beat
  201: HEADER page, at the beginning of the EEPROM
       bytes 7 & 8 specify the location of the next blank page.
at some future point, there will be more types, like for instance it
would be cool to have a type that stored the average BPM for 1 minute
intervals in each byte, thus giving the pendant a logging time
of weeks instead of hours.

Bytes 1-6: Date/Time, the time of the FIRST data point in this set
 year month dayOfMonth hour minute second

Bytes 7-127: data, as specified by the type.  

HEADER page: for storing pointer to the next location to be written
Byte 7: eecounter, the next-to-be-written data page
Byte 8: tosendindex, the location inside that page to be written next
  (note that tosendindex is currently useless since we do not write
   partial pages)

*/
  
  if (ToSendIndex == 0)
  {
    getDate8536();
    // structure the new data page:
    ToSend[0] = 101;  // for now, this is the only implimented data type
    ToSend[1] = year;
    ToSend[2] = month;
    ToSend[3] = dayOfMonth;
    ToSend[4] = hour;
    ToSend[5] = minute;
    ToSend[6] = second;
    ToSendIndex = 7;  // where the first data will land
    for (i = 7; i<128; i++)
      ToSend[i] = 0;  // clear the buffer of old data
    //if (Chatter) Serial.println("Starting New Page");
  }
  // append the new heart rate data, increment pointer
  ToSend[ToSendIndex++] = HeartRate;
    
  if (ToSendIndex == 128)
  {  // then we just filled the last data slot, log this data to EEPROM
    // let's write 4 30-byte chunks and one 8-byte chunk
    for (i = 0; i<4; i++)
    {
      i2c_eeprom_write_page(EEPROM_I2C_ADDRESS, eecounter*128+i*30,&ToSend[i*30], 30);
      delay(4); // delay 4ms, because the EEPROM will ignore everything
          // for that long, basically until it's done writing that page...
    }
    i2c_eeprom_write_page(EEPROM_I2C_ADDRESS, eecounter*128+120,&ToSend[120], 8);   
    delay(4);
    ToSendIndex = 0; 
    eecounter++;  // move to next page in EEPROM
    WriteHeaderPage();  // we used to do this in ToSendIndex == 0 but it's better here
        // because there was always the chance that something would happen
        // between now and the next loop iteration... and that could result
        // in loosing this page of data!
    if (Chatter) Serial.print("Saved Data to EEPROM: ");
    if (Chatter) PrintBuffer();
    EEPROM_Blink();
  }
}

void WriteHeaderPage()
{
    //getDateDs1307();
    getDate8536();
    
    // structure the header page
    ToSend[0] = 201;
    ToSend[1] = year;
    ToSend[2] = month;
    ToSend[3] = dayOfMonth;
    ToSend[4] = hour;
    ToSend[5] = minute;
    ToSend[6] = second;
    ToSend[7] = eecounter;
    ToSend[8] = ToSendIndex;
    for (i = 9; i<128; i++)
      ToSend[i] = 0;
    
    // write to address 0, the first page of the EEPROM, which
    // is reserved for the header page.
    i2c_eeprom_write_page(EEPROM_I2C_ADDRESS, 0,&ToSend[0], 30);
}

void PrintBuffer()
{
  //Serial.println("Buffer: ");
  // NOTE: this must always chatter, since it's used by HandleSerial
  for (i=0; i<128; i++)
  {
    Serial.print(ToSend[i], DEC);
    Serial.print(",");
  }
  Serial.println();
}

void ModeChangeFlash()
{
  digitalWrite(LED6, HIGH);
  delay(150);
  digitalWrite(LED6, LOW);
  digitalWrite(LED5, HIGH);
  digitalWrite(LED1, HIGH);
  delay(150);
  digitalWrite(LED6, HIGH);
  digitalWrite(LED5, LOW);
  digitalWrite(LED1, LOW);
  delay(150);
  digitalWrite(LED6, LOW);
}

void EEPROM_Blink()
{
  digitalWrite(LED2, HIGH);
  delay(150);
  digitalWrite(LED2, LOW);
  digitalWrite(LED4, HIGH);
  delay(150);
  digitalWrite(LED2, HIGH);
  digitalWrite(LED4, LOW);
  delay(150);
  digitalWrite(LED2, LOW);
}

void Error_Blink()
{  // blink this when we encounter an irrecoverable error
   // blink the bottom LED three times: low power, very distinctive
  digitalWrite(LED3, HIGH);
  delay(150);
  digitalWrite(LED3, LOW);
  delay(150);
  digitalWrite(LED3, HIGH);
  delay(150);
  digitalWrite(LED3, LOW);
  delay(150);
  digitalWrite(LED3, HIGH);
  delay(150);
  digitalWrite(LED3, LOW);
}

void Startup_Blink()
{
  digitalWrite(LED3, HIGH);
  delay(150);
  digitalWrite(LED3, LOW);
  digitalWrite(LED6, HIGH);
  delay(150);
  digitalWrite(LED3, HIGH);
  digitalWrite(LED6, LOW);
  delay(150);
  digitalWrite(LED3, LOW);
}

void PolarInterrupt(void)
{
  PolarIRQ = true;  // set flag and let main loop handle it
}

void PolarCalcs(void)
{
  unsigned long time;
  unsigned long NewPolar = 0;
  // this is an interrupt called function!!
  if (digitalRead(POLARout) && (Mode != 2))  // make sure it was a RISING edge
  {
    time = millis();
    NewPolar = time - LastTime;
    
    if ((NewPolar > 0.60*PolarTime) || (NewPolar > 1000) || NoSecondSkip || (PolarTime > 1000))
    {  // filtering, kill "half" beats, but don't want to make
       // any additional "false negatives" by being too agressive
       // NOTE: must have (PolarTime > 1000) argument, because it prevents the
       // horrible case where the previous time took forever and you get trapped
       // in a cycle of VERY LOW BMP, discarding every other heart beat
       // note that we can still get into that kind of mode if the user has
       // an elevated heart-beat, we should probably write a detector
       // for that kind of situation, but I am too lazy to do it for now.
      NoSecondSkip = 0;
      PolarTime = NewPolar;
      HeartRate = 60000/PolarTime;
      if (HeartRate > 255) HeartRate = 255;

      if (Chatter)
      {
         Serial.print("Polar Interrupt: ");
         Serial.print(HeartRate);
         Serial.print(" BPM, ");
         Serial.print(PolarTime);
         Serial.println(" ms");
      }
      LastTime = time;
      setblink = 1;  // trigger code in the main loop
    }
    else
    {
      NoSecondSkip = 1;
      if (Chatter) Serial.println("Polar Interrupt: false positive");
    }
  }
  else if (Mode == 2)
  {
    if (Chatter) Serial.print("Polar Interrupt during Fake Mode: ");
    time = millis();
    NewPolar = time - LastTime;
    LastTime = time;
    HeartRate = 60000/NewPolar;

    // if it's a "reasonable" heart beat then count it 
    //    towards the end of Fake Mode (10 real beats required)
    // NOTE: this check is necessary because if the chest strap is 
    // close but not on you (like, in your backpack), it will send
    // out a considerable number of pulses - about 3/minute, actually
    // so any non-filtering counter will be quickly overwhelmed...
    if ((NewPolar < 1200) && (HeartRate != 81))
    {  
      BlinkCount++; 
      if (Chatter) 
      {
        Serial.print("Counted: ");
        Serial.print(HeartRate, DEC);
        Serial.print(" BPM; number");
        Serial.print(BlinkCount);
        //Serial.println(" of 10");
      }
    }
    else
    {
      if (Chatter)
      {
        Serial.print("not counted: ");
        Serial.print(HeartRate);
        Serial.println(" BPM");
      }
    }
  }
}

void blink_leds(void)
{ // NOTE: this is OLD way, with no sleeping
  //if (Chatter) Serial.println("flash");
  // pattern: ON for 20ms, off for 120, on again for 10, then off
  ChangeLEDs(HIGH);
  delay(20);
  ChangeLEDs(LOW);
  delay(120);
  ChangeLEDs(HIGH);
  delay(10);
  ChangeLEDs(LOW);
}


void fake_blink(void)
{ // NOTE: this is OLD way, with no sleeping
  //if (Chatter) Serial.println("flash");
  // pattern: ON for 20ms, off for 120, on again for 10, then off
  ChangeLEDs(HIGH);
  delay(20);
  ChangeLEDs(LOW);
  delay(120);
  ChangeLEDs(HIGH);
  delay(10);
  ChangeLEDs(LOW);
}


void activity_blink()
{ // blink MORE LEDs when the heart rate is bigger
  if (HeartRate < 80)
  {
    digitalWrite(LED2, HIGH);
    digitalWrite(LED4, HIGH);
    delay(20);
    digitalWrite(LED2, LOW);
    digitalWrite(LED4, LOW);
    delay(120);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED4, HIGH);
    delay(10);
    digitalWrite(LED2, LOW);
    digitalWrite(LED4, LOW);
  }
  else if (HeartRate < 90)
  {
    digitalWrite(LED2, HIGH);
    digitalWrite(LED3, HIGH);
    digitalWrite(LED4, HIGH);
    delay(20);
    digitalWrite(LED2, LOW);
    digitalWrite(LED3, LOW);
    digitalWrite(LED4, LOW);
    delay(120);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED3, HIGH);
    digitalWrite(LED4, HIGH);
    delay(10);
    digitalWrite(LED2, LOW);
    digitalWrite(LED3, LOW);
    digitalWrite(LED4, LOW);
  }
  else if (HeartRate < 100)
  {
    digitalWrite(LED1, HIGH);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED4, HIGH);
    digitalWrite(LED5, HIGH);
    delay(20);
    digitalWrite(LED1, LOW);
    digitalWrite(LED2, LOW);
    digitalWrite(LED4, LOW);
    digitalWrite(LED5, LOW);
    delay(120);
    digitalWrite(LED1, HIGH);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED4, HIGH);
    digitalWrite(LED5, HIGH);
    delay(10);
    digitalWrite(LED1, LOW);
    digitalWrite(LED2, LOW);
    digitalWrite(LED4, LOW);
    digitalWrite(LED5, LOW);
  }
  else if (HeartRate < 110)
  {
    digitalWrite(LED1, HIGH);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED3, HIGH);
    digitalWrite(LED4, HIGH);
    digitalWrite(LED5, HIGH);
    delay(20);
    digitalWrite(LED1, LOW);
    digitalWrite(LED2, LOW);
    digitalWrite(LED3, LOW);
    digitalWrite(LED4, LOW);
    digitalWrite(LED5, LOW);
    delay(120);
    digitalWrite(LED1, HIGH);
    digitalWrite(LED2, HIGH);
    digitalWrite(LED3, HIGH);
    digitalWrite(LED4, HIGH);
    digitalWrite(LED5, HIGH);
    delay(10);
    digitalWrite(LED1, LOW);
    digitalWrite(LED2, LOW);
    digitalWrite(LED3, LOW);
    digitalWrite(LED4, LOW);
    digitalWrite(LED5, LOW);
  }
  else
  {
    ChangeLEDs(HIGH);
    delay(20);
    ChangeLEDs(LOW);
    delay(120);
    ChangeLEDs(HIGH);
    delay(10);
    ChangeLEDs(LOW);
  }
}


void fancy2_blink()
{
  int ontime = 40;
  digitalWrite(LED1, HIGH);
  delay(ontime);  
  digitalWrite(LED2, HIGH);  
  delay(ontime);  
  digitalWrite(LED1, LOW);  
  digitalWrite(LED3, HIGH);  
  delay(ontime);  
  digitalWrite(LED2, LOW);  
  digitalWrite(LED4, HIGH);  
  delay(ontime);  
  digitalWrite(LED3, LOW);  
  digitalWrite(LED5, HIGH);  
  delay(ontime);  
  digitalWrite(LED4, LOW);  
  digitalWrite(LED6, HIGH);  
  delay(ontime);  
  digitalWrite(LED5, LOW);
  delay(ontime);  
  digitalWrite(LED6, LOW);  
}


/*
void fade_blink()
{
// apparently the ATMEGA likes this way more as a global than as a local
// in the fade_blink loop.  As a local it causes the ATMEGA to crash
// on a fairly regular basis?!?
// UPDATE: even as a global this thing causes crashes, just less
// frequenctly, is all...
//byte valueArray[32] = {1,2, 4, 5, 7, 9, 11, 13, 16, 18, 22, 25, 29, 33, 38, 43, 48, 55, 61, 69, 78, 87, 97, 109, 121, 135, 150, 167, 186, 207, 230, 255};  
  
  // timer2 handles PWM on pins 3 and 11, must free it up to get this to work
  MsTimer2::stop();
  resetTimer2();
  //int value;
  //long time1 = millis();
  //long time2;
  //float overThirty = 1.0/30.0;
  //float top = 255.0/exp(127.0*overThirty);
  //byte valueArray[128];
  
  //Serial.println("starting up half");
  
  for (i = 0; i<32; i++)
  {
    analogSetAllLEDs(valueArray[i]);
    delay(2);
  }
  for (i = 0; i<32; i++)
  {
    analogSetAllLEDs(valueArray[31-i]);
    delay(2);
  }

  /*
  for (i = 0; i<128; i++)
  {  
    //valueArray[i] = (byte)((float)exp((float)i*overThirty)*top);
    //analogSetAllLEDs(valueArray[i]);
    value = (byte)((float)exp((float)i*overThirty)*top);
    analogSetAllLEDs(value);
    //int test = valueArray[i];
    //Serial.print(test);
    //Serial.print(", ");
    //delayMicroseconds(50);
    //Serial.println(i);
  }
  for (i = 0; i<128; i++)
  {
    value = (int)((float)exp((float)(128-i)*overThirty)*top);
    analogSetAllLEDs(value);

    //delayMicroseconds(500);
    //analogSetAllLEDs(valueArray[127-i]);
    //Serial.println(valueArray[127-i]);
  }
  */
  

  /*
  for (i = 0; i<128; i++)
  {
    int test = valueArray[i];
    Serial.print(test);
    Serial.print(", ");
  }  
  Serial.println("");
  */

  /*
  for (i = 0; i<64; i++)
  {
    analogSetAllLEDs(i*4);
    delay(1);
  }
  for (i = 0; i<64; i++)
  {
    analogSetAllLEDs(255-i*4);
    delay(1);
  }
  */
  
  //time2 = millis();
  //if (Chatter) Serial.println(time2-time1);
  
  /*
  ChangeLEDs(LOW);  // don't analogWrite 0, that'll mess up when
    // Timer2 is changed...

  if (Mode == 2)
  {  
    MsTimer2::set(600, StartFakeBlink);
    MsTimer2::start();      
  }
}
*/
/*
void resetTimer2()
{
	  // set timer 2 prescale factor to 64
#if defined(__AVR_ATmega8__)
	  TCCR2 |= (1<<CS22);
#else
	 TCCR2B |= (1<<CS22);
#endif
	// configure timer 2 for phase correct pwm (8-bit)
#if defined(__AVR_ATmega8__)
	TCCR2 |= (1<<WGM20);
#else
	TCCR2A |= (1<<WGM20);
#endif
  
} 
*/

/*
void analogSetAllLEDs(int setting)
{
  analogWrite(LED1, setting);
  analogWrite(LED2, setting);
  analogWrite(LED3, setting);
  analogWrite(LED4, setting);
  analogWrite(LED5, setting);
  analogWrite(LED6, setting);
}
*/

/*
void blink_leds_lowpower(void)
{
  //if (Chatter) Serial.println("flash");
  // pattern: ON for 20ms, off for 120, on again for 10, then off
  
  if (SleepBlinkStep == 1)
  {
    SleepBlinkStep += 100;  // don't call this step repetidly!!
    ChangeLEDs(HIGH);
    MsTimer2::set(20, SleepingBlinkNextStep);
    MsTimer2::start();
  }
  else if (SleepBlinkStep == 2)
  {
    SleepBlinkStep += 100;  // don't call this step repetidly!!
    ChangeLEDs(LOW);
    MsTimer2::set(120, SleepingBlinkNextStep);
    MsTimer2::start();
  }
  else if (SleepBlinkStep == 3)
  {
    SleepBlinkStep += 100;  // don't call this step repetidly!!
    ChangeLEDs(HIGH);
    MsTimer2::set(10, SleepingBlinkNextStep);
    MsTimer2::start();
  }
  else if (SleepBlinkStep == 4)
  {
    SleepBlinkStep = 0;  // we're done!
    ChangeLEDs(LOW);
    if (Mode == 2)  // fake mode!
    {
      MsTimer2::set(600, StartFakeBlink);
      MsTimer2::start();      
    }
  }
}

void SleepingBlinkNextStep()
{  // interrupt called function!
    MsTimer2::stop();
    SleepBlinkStep = SleepBlinkStep -100 +1;
}
*/

void ChangeLEDs(int which)
{
  digitalWrite(LED1, which);
  digitalWrite(LED2, which);
  digitalWrite(LED3, which);
  digitalWrite(LED4, which);
  digitalWrite(LED5, which);
  digitalWrite(LED6, which);  
}

void GetSetDate()
{
  // ok, get some stuff over Serial and use it to set the date
  // FIRST: respond saying "I'm ready"
  byte bufferedValue = 0;
  boolean MoreData = true;
  int xValue = 0;
  int loopCount = 0;
  
  Serial.print("D");
  
  while(MoreData){
    while(Serial.available() == 0){delay(1);}
    bufferedValue = Serial.read();
    //print((char)bufferedValue);
     
    if ( (bufferedValue == '\r') || (loopCount == 6))
    {
      MoreData = false;
      break;
    }

    xValue = 0;
    while(bufferedValue != ',') {
      // converts the Serial input, which is a stream of ascii characters, to integers
      // Shift the the current digits left one place
      xValue*= 10;
      // add the next value in the stream
      xValue += (bufferedValue - 48);
      while(Serial.available() == 0){delay(1);}      
      bufferedValue = Serial.read();
    }
    if (loopCount == 0) year = xValue;
    else if (loopCount == 1) month = xValue;
    else if (loopCount == 2) dayOfMonth = xValue;
    else if (loopCount == 3) hour = xValue;
    else if (loopCount == 4) minute = xValue;
    else if (loopCount == 5) second = xValue;
    Serial.print(xValue);
    Serial.print(",");
    loopCount++;
  }
  
  /*  if you want to override using the IDE, here are the lines to set
  year = 10;   // 2010 = 10, 2011 = 11, etc.
  month = 11;
  dayOfMonth = 24;
  dayOfWeek = 2;
  hour = 19;
  minute = 24;
  second = 1;
  */
  // clear serial from any extra crap, like \r\n or whatever...
  while (Serial.available() != 0) {Serial.read();}
  //setDateDs1307();
  setDate8536();
  Serial.println("  FINISHED setting date");
}






// EEPROM I2C interfacing code from
// http://www.arduino.cc/playground/Code/I2CEEPROM

void i2c_eeprom_write_byte( int deviceaddress, unsigned int eeaddress, byte data ) {
    int rdata = data;
    Wire.beginTransmission(deviceaddress);
    Wire.send((int)(eeaddress >> 8)); // MSB
    Wire.send((int)(eeaddress & 0xFF)); // LSB
    Wire.send(rdata);
    Wire.endTransmission();
}

// WARNING: data can be maximum of about 30 bytes, because the Wire library has a buffer of 32 bytes
void i2c_eeprom_write_page( int deviceaddress, unsigned int eeaddresspage, byte* data, byte length ) {
    Wire.beginTransmission(deviceaddress);
    Wire.send((int)(eeaddresspage >> 8)); // MSB
    Wire.send((int)(eeaddresspage & 0xFF)); // LSB
    byte c;
    
    //Serial.print("write_page: ");
    for ( c = 0; c < length; c++)
    {
      Wire.send(data[c]);
      //Serial.print(data[c], DEC);
      //Serial.print(" ");
    }
    //Serial.println();
    Wire.endTransmission();
}

byte i2c_eeprom_read_byte( int deviceaddress, unsigned int eeaddress ) {
    byte rdata = 0xFF;
    Wire.beginTransmission(deviceaddress);
    Wire.send((int)(eeaddress >> 8)); // MSB
    Wire.send((int)(eeaddress & 0xFF)); // LSB
    Wire.endTransmission();
    Wire.requestFrom(deviceaddress,1);
    if (Wire.available()) rdata = Wire.receive();
    return rdata;
}

void i2c_eeprom_read_buffer( int deviceaddress, unsigned int eeaddress, byte *buffer, int length ) {
    Wire.beginTransmission(deviceaddress);
    Wire.send((int)(eeaddress >> 8)); // MSB
    Wire.send((int)(eeaddress & 0xFF)); // LSB
    Wire.endTransmission();
    Wire.requestFrom(deviceaddress,length);
    int c = 0;
    
    //Serial.print("read_buffer ");
    for ( c = 0; c < length; c++ )
    {
      if (Wire.available()) buffer[c] = Wire.receive();
      //Serial.print(buffer[c], DEC);
      //Serial.print(" ");
    }
    //Serial.println();
}



// ***** RTC Functions ******
// **************************
// 1) Sets the date and time on the ds1307
// 2) Starts the clock
// 3) Sets hour mode to 24 hour clock
// Assumes you're passing in valid numbers.
void setDateDs1307(){
   //Wire.beginTransmission(DS1307_I2C_ADDRESS);
   Wire.beginTransmission(PCF8563_I2C_ADDRESS);
   Wire.send(0);
   Wire.send(decToBcd(second));
   Wire.send(decToBcd(minute));
   Wire.send(decToBcd(hour));
   Wire.send(decToBcd(dayOfWeek));
   Wire.send(decToBcd(dayOfMonth));
   Wire.send(decToBcd(month));
   Wire.send(decToBcd(year));
   Wire.endTransmission();
}

void setDate8536(){
   //Wire.beginTransmission(DS1307_I2C_ADDRESS);
   Wire.beginTransmission(PCF8563_I2C_ADDRESS);
   Wire.send(2);
   Wire.send(decToBcd(second));
   Wire.send(decToBcd(minute));
   Wire.send(decToBcd(hour));
   Wire.send(decToBcd(dayOfMonth));
   Wire.send(decToBcd(dayOfWeek));
   Wire.send(decToBcd(month));
   Wire.send(decToBcd(year));
   Wire.endTransmission();
}

void set8536_ClkOut(){
   //Wire.beginTransmission(DS1307_I2C_ADDRESS);
   Wire.beginTransmission(PCF8563_I2C_ADDRESS);
   Wire.send(0x0D);  // CLK_out register at 0D
   Wire.send(0x80);  // bit 7 = turn on, bits 0 & 1 low = 32.768kHz
   Wire.endTransmission();
}

void read8536_ClkOut(){
  int val = 0;
  Wire.beginTransmission(PCF8563_I2C_ADDRESS);
  Wire.send(0x0D);
  Wire.endTransmission();
  Wire.requestFrom(PCF8563_I2C_ADDRESS, 1);
  
  val = Wire.receive();
  Serial.print("ClkOut: ");
  Serial.println(val, DEC);
}



// Gets the date and time from the ds1307
void getDate8536()
{
  int i = 0;
  Wire.beginTransmission(PCF8563_I2C_ADDRESS);
  Wire.send(2);
  Wire.endTransmission();
  Wire.requestFrom(PCF8563_I2C_ADDRESS, 7);
  
  second     = bcdToDec(Wire.receive() & 0x7f);
  minute     = bcdToDec(Wire.receive() & 0x7F);
  hour	 = bcdToDec(Wire.receive() & 0x3f);
  dayOfMonth = bcdToDec(Wire.receive() & 0x3F);
  dayOfWeek  = bcdToDec(Wire.receive() & 0x07);
  month	= bcdToDec(Wire.receive() & 0x1F);
  year	 = bcdToDec(Wire.receive());
}

void getDateDs1307()
{
  int i = 0;
  Wire.beginTransmission(DS1307_I2C_ADDRESS);
  Wire.send(0);
  Wire.endTransmission();
  Wire.requestFrom(DS1307_I2C_ADDRESS, 7);
  
  second     = bcdToDec(Wire.receive() & 0x7f);
  minute     = bcdToDec(Wire.receive());
  hour	 = bcdToDec(Wire.receive() & 0x3f);
  dayOfWeek  = bcdToDec(Wire.receive());
  dayOfMonth = bcdToDec(Wire.receive());
  month	= bcdToDec(Wire.receive());
  year	 = bcdToDec(Wire.receive());
}



// Convert normal decimal numbers to binary coded decimal
byte decToBcd(byte val)
{
  return ( (val/10*16) + (val%10) );
}

// Convert binary coded decimal to normal decimal numbers
byte bcdToDec(byte val)
{
  return ( (val/16*10) + (val%16) );
}

