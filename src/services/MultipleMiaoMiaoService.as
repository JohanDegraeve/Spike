package services
{
	import com.distriqt.extension.networkinfo.NetworkInfo;
	import com.hurlant.crypto.hash.SHA1;
	import com.hurlant.util.Hex;
	import com.spikeapp.spike.airlibrary.SpikeANE;
	
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.TimerEvent;
	import flash.net.URLLoader;
	import flash.net.URLRequestMethod;
	import flash.net.URLVariables;
	import flash.utils.Timer;
	
	import spark.formatters.DateTimeFormatter;
	
	import database.BgReading;
	import database.CGMBlueToothDevice;
	import database.Calibration;
	import database.CommonSettings;
	import database.LocalSettings;
	import database.Sensor;
	
	import events.SettingsServiceEvent;
	import events.TransmitterServiceEvent;
	
	import network.NetworkConnector;
	
	import utils.DateTimeUtilities;
	import utils.SpikeJSON;
	import utils.Trace;
	import utils.libre.CalibrationData;
	import utils.libre.GlucoseData;

	public class MultipleMiaoMiaoService
	{
		/* Constants */
		private static const TIME_8_HOURS:int = 8 * 60 * 60 * 1000;
		private static const TIME_1_HOUR:int = 60 * 60 * 1000;
		private static const TIME_4_MINUTES_30_SECONDS:int = (4 * 60 * 1000) + 30000;
		private static const MODE_GLUCOSE_READING_GET:String = "glucoseReadingGet";
		private static const MODE_CALIBRATION:String = "calibration";

		//timers
		//timer to reconnect to MiaoMiao
		private static var reconnectTimer:Timer;
		//timer to check if reading was received on time
		private static var checkReadingTimer:Timer;
		
		//NightScout download
		private static var nightscoutDownloadURL:String = "";
		private static var nightscoutTreatmentsURL:String = "";
		private static var nightscoutDownloadOffset:Number = 0;
		private static var nightscoutDownloadAPISecret:String = "";
		private static var waitingForNSData:Boolean = false;
		private static var lastNSDownloadAttempt:Number;
		private static var timeOfFirstBgReadingToDowload:Number;
		private static var timeOfFirstCalibrationToDowload:Number;
		private static var bgReadingAndCalibrationsList:Array;//arraylist of glucosedata and calibrations
		private static var firstTime:Boolean;
		
		/* Objects */
		private static var hash:SHA1 = new SHA1();
		private static var formatter:DateTimeFormatter;
		private static var logstring:String;
	
		public function MultipleMiaoMiaoService() {
		}
		
		public static function init():void {
			myTrace("init");
			CommonSettings.instance.addEventListener(SettingsServiceEvent.SETTING_CHANGED, commonSettingChanged);
			
			formatter = new DateTimeFormatter();
			formatter.dateTimePattern = "yyyy-MM-dd'T'HH:mm:ss.SSSZ";
			formatter.setStyle("locale", "en_US");
			formatter.useUTC = true;

			//initialize variables
			setupService();
			
			//immediately start with checking if we have the latest reading
			checkLatestReading();
		}

		private static function bgReadingReceived(be:TransmitterServiceEvent):void {
			if (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_MIAOMIAO_MULTIPLE_DEVICE_ON) == "true"
				&&
				CGMBlueToothDevice.isMiaoMiao()) {
				//temporary disconnecting to allow other ios device to connect to the miaomiao
				//It doesn't harm to make this call even if there's no miaomiao connection for the moment
				SpikeANE.disconnectMiaoMiao();
				
				if (reconnectTimer != null && reconnectTimer.running) {
					myTrace("reconnectTimer already running, not restarting");
				} else {
					//set reconnecttimer to 10 seconds
					reconnectTimer = new Timer(10 * 1000, 1);
					reconnectTimer.addEventListener(TimerEvent.TIMER, reconnect);
					reconnectTimer.start();
				}
				
				//start timer to verify if new reading was received on time
				if (checkReadingTimer != null && checkReadingTimer.running) {
					myTrace("checkReadingTimer already running, not restarting");
				} else {
					//set checkReadingTimer to 5 minutes and 20 seconds
					resetCheckReadingTimer(5 * 60 + 20);
				}
			}
		}
		
		private static function resetCheckReadingTimer(delayInSeconds:Number):void {
			myTrace("in resetCheckReadingTimer");
			if (checkReadingTimer != null && checkReadingTimer.running) {
				checkReadingTimer.stop();
			}
			if (isNaN(delayInSeconds)) {
				myTrace("in resetCheckReadingTimer but delayInSeconds is NAN, not starting timer");			
			} else {
				myTrace("in resetCheckReadingTimer setting timer with delay " + delayInSeconds);	
				checkReadingTimer = new Timer(delayInSeconds * 1000, 1);
				checkReadingTimer.addEventListener(TimerEvent.TIMER, checkLatestReading);
				checkReadingTimer.start();
			}
		}
		
		private static function checkLatestReading(event:Event = null):void {
			var now:Number = (new Date()).valueOf();
			if (isMiaoMiaoMultiple() && Sensor.getActiveSensor() != null) {
				myTrace("in checkLatestReading");

				if (nightscoutDownloadURL == "") {
					myTrace("in checkLatestReading, nightscoutDownloadURL is not set. Aborting!");
					return;
				}
				
				bgReadingAndCalibrationsList = new Array();
				
				var latestBGReading:BgReading = BgReading.lastNoSensor();
				if (latestBGReading != null && !isNaN(latestBGReading.timestamp) && now - latestBGReading.timestamp < 5 * 60 * 1000) {
					myTrace("in checkLatestReading, there's a reading less than 5 minutes old");
					resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, latestBGReading));
					timeOfFirstBgReadingToDowload = latestBGReading.timestamp + 1;//value will be used in checkLatestCalibration
					//there might be a recent calibration uploaded by another device
					checkLatestCalibration();
					return;
				}

				
				if (!NetworkInfo.networkInfo.isReachable()) {
					myTrace("in checkLatestReading, There's no Internet connection. Will try again later!");
					resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, latestBGReading));
					return;
				}
				
				if (latestBGReading == null) 
					timeOfFirstBgReadingToDowload = now - TIME_8_HOURS;
				else
					timeOfFirstBgReadingToDowload = latestBGReading.timestamp + 1; //We add 1ms to avoid overlaps
				
				var numberOfReadings:Number = ((now - timeOfFirstBgReadingToDowload) / TIME_1_HOUR * 12) + 1; //Add one more just to make sure we get all readings
				var parameters:URLVariables = new URLVariables();
				parameters["find[dateString][$gte]"] = timeOfFirstBgReadingToDowload;
				parameters["count"] = Math.round(numberOfReadings);
				
				waitingForNSData = true;
				lastNSDownloadAttempt = (new Date()).valueOf();
				
				NetworkConnector.createNSConnector(nightscoutDownloadURL + parameters.toString(), nightscoutDownloadAPISecret != "" ? nightscoutDownloadAPISecret : null, URLRequestMethod.GET, null, MODE_GLUCOSE_READING_GET, onDownloadGlucoseReadingsComplete, onConnectionFailed);
			}
			
			//resetting checkreadingtimer, just in case it does'nt get reset anymore, although it should while processing received readings and/or calibrations
			resetCheckReadingTimer(now + 5 * 60 * 1000);
		}
		
		private static function onConnectionFailed(error:Error, mode:String):void
		{
			if (mode == MODE_GLUCOSE_READING_GET)
			{
				myTrace("in onConnectionFailed. Can't make connection to the server while trying to download glucose readings. Error: " +  error.message);
			}
			if (mode == MODE_CALIBRATION)
			{
				myTrace("in onConnectionFailed. Can't make connection to the server while trying to download calibration. Error: " +  error.message);
				//there might be glucose readings waiting to be processed
				processReadingsAndCalibrations();
			}
			resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds((new Date()).valueOf(), BgReading.lastNoSensor()));
		}
		

		private static function onDownloadGlucoseReadingsComplete(e:Event):void {
			myTrace("in onDownloadGlucoseReadingsComplete");

			var glucoseData:GlucoseData;
			var now:Number = (new Date()).valueOf();
			
			//Validate call
			if (!waitingForNSData || (now - lastNSDownloadAttempt > TIME_4_MINUTES_30_SECONDS)) {
				myTrace("in onDownloadGlucoseReadingsComplete, Not waiting for data or last download attempt was more than 4 minutes, 30 seconds ago. Ignoring!");
				waitingForNSData = false;
				resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, BgReading.lastNoSensor()));
				return;
			}
			
			waitingForNSData = false;
			
			var response:String = getResponseAndDisposeLoader(e, onDownloadGlucoseReadingsComplete, onConnectionFailed);
			
			//Validate response
			if (response.length == 0) {
				myTrace("in onDownloadGlucoseReadingsComplete, Server's gave an empty response. Retry later.");
				resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, BgReading.lastNoSensor()));
				return;
			}
						
			try {
				var NSResponseJSON:Object = SpikeJSON.parse(response);
				if (NSResponseJSON is Array) {
					var NSBgReadings:Array = NSResponseJSON as Array;
					
					myTrace("in onDownloadGlucoseReadingsComplete, received " + NSBgReadings.length + " readings.");
					for(var arrayCounter:int = NSBgReadings.length - 1 ; arrayCounter >= 0; arrayCounter--) {
						var NSDownloadReading:Object = NSBgReadings[arrayCounter];
						if (NSDownloadReading.date) {
							var NSDownloadReadingDate:Date = new Date(NSDownloadReading.date);
							NSDownloadReadingDate.setMinutes(NSDownloadReadingDate.minutes + nightscoutDownloadOffset);
							var NSDownloadReadingTime:Number = NSDownloadReadingDate.valueOf();
							if (NSDownloadReadingTime >= timeOfFirstBgReadingToDowload) {
								glucoseData = new GlucoseData();
								glucoseData.glucoseLevelRaw = NSDownloadReading.unfiltered as int;
								glucoseData.realDate = NSDownloadReadingTime;
								bgReadingAndCalibrationsList.push(glucoseData);
								myTrace("in onDownloadGlucoseReadingsComplete, adding glucosedata with realdate =  " + (new Date(NSDownloadReadingTime)).toString() + " and value = " + glucoseData.glucoseLevelRaw);
							} else {
								myTrace("in onDownloadGlucoseReadingsComplete, ignored with realdate =  " + (new Date(NSDownloadReadingTime)).toString() + " because timestamp < " + (new Date(timeOfFirstBgReadingToDowload)).toString());
							}
						} else {
							myTrace("in onDownloadGlucoseReadingsComplete, Nightscout has returned a reading without date. Ignoring!");
							if (NSDownloadReading._id)
								myTrace("in onDownloadGlucoseReadingsComplete, Reading ID: " + NSDownloadReading._id);
						}
					}
					if (!checkLatestCalibration())
						processReadingsAndCalibrations();
				} 
				else 
					myTrace("in onDownloadGlucoseReadingsComplete, Nightscout response was not a JSON array. Ignoring! Response: " + response);
			} 
			catch (error:Error) 
			{
				myTrace("in onDownloadGlucoseReadingsComplete, Error parsing Nightscout responde! Error: " + error.message + " Response: " + response);
			}
			
			resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, BgReading.lastNoSensor()));
		}
		
		private static function processReadingsAndCalibrations():void {
			//process readings and calibrations that have been downloaded from NS
			var newBGReading:Boolean = false;
			var newCalibration:Boolean = false;
			
			//temporary remove the eventlistener, because BGREADING_EVENTs are going to be dispatched 
			TransmitterService.instance.removeEventListener(TransmitterServiceEvent.LAST_BGREADING_RECEIVED, bgReadingReceived);

			bgReadingAndCalibrationsList.sortOn(["realDate"], Array.NUMERIC);
			
			//process all readings
			for (var cntr:int = 0; cntr < bgReadingAndCalibrationsList.length ;cntr ++) {
				if (bgReadingAndCalibrationsList[cntr] is GlucoseData) {
					var gd:GlucoseData = bgReadingAndCalibrationsList[cntr] as GlucoseData;
					if (gd.glucoseLevelRaw > 0) {
						newBGReading = true;
						BgReading.create(gd.glucoseLevelRaw, gd.glucoseLevelRaw, gd.realDate).saveToDatabaseSynchronous();
						myTrace("in processReadingsAndCalibrations, created bgreading at: " + (new Date(gd.realDate)).toString() + ", with unfiltered value " + gd.glucoseLevelRaw);
						
						//to avoid that NightScoutService would re-upload the readings to NightScout, set COMMON_SETTING_NIGHTSCOUT_UPLOAD_BGREADING_TIMESTAMP
						if (gd.realDate > new Number(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_UPLOAD_BGREADING_TIMESTAMP))) {
							CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_UPLOAD_BGREADING_TIMESTAMP, gd.realDate.toString());
						}
						
						TransmitterService.dispatchBgReadingReceivedEvent();
					} else {
						myTrace("in processReadingsAndCalibrations, received glucoseLevelRaw = 0");
					}
				} else {
					var calibration:CalibrationData = bgReadingAndCalibrationsList[cntr] as CalibrationData;
					if (calibration.glucoseLevelRaw > 0) {
						newCalibration = true;
						myTrace("in processReadingsAndCalibrations, created calibration");
						Calibration.create(calibration.glucoseLevelRaw,  calibration.realDate).saveToDatabaseSynchronous();
						
						//to avoid that NightScoutService would re-upload the readings to NightScout, set COMMON_SETTING_NIGHTSCOUT_UPLOAD_CALIBRATION_TIMESTAMP
						if (calibration.realDate > new Number(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_UPLOAD_CALIBRATION_TIMESTAMP))) {
							CommonSettings.setCommonSetting(CommonSettings.COMMON_SETTING_NIGHTSCOUT_UPLOAD_CALIBRATION_TIMESTAMP, calibration.realDate.toString());
						}
						
					} else {
						myTrace("in processReadingsAndCalibrations, received glucoseLevelRaw = 0");
					}
				}
			}
						
			//Notify Listeners that there's a new bgreading if any
			if (newBGReading)
				TransmitterService.dispatchLastBgReadingReceivedEvent();
			
			//reinitialise the array
			bgReadingAndCalibrationsList = new Array();

			//readd the eventlistener for new readings
			TransmitterService.instance.addEventListener(TransmitterServiceEvent.LAST_BGREADING_RECEIVED, bgReadingReceived);
						
			resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds((new Date()).valueOf(), BgReading.lastNoSensor()));
		}
		
		private static function onDownloadCalibrationsComplete(e:Event):void {
			myTrace("in onDownloadCalibrationsComplete");
			
			var calibrationData:CalibrationData;
			var now:Number = (new Date()).valueOf();
			
			//Validate call
			if (!waitingForNSData) {
				myTrace("in onDownloadCalibrationsComplete, Not waiting for data. Ignoring!");
				waitingForNSData = false;
				resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, BgReading.lastNoSensor()));
				return;
			}
			
			waitingForNSData = false;
			
			var response:String = getResponseAndDisposeLoader(e, onDownloadCalibrationsComplete, onConnectionFailed);
			
			//Validate response
			if (response.length == 0) {
				myTrace("in onDownloadCalibrationsComplete, Server's gave an empty response. Retry later.");
				processReadingsAndCalibrations();
				return;
			}
			
			try {
				var NSResponseJSON:Object = SpikeJSON.parse(response);
				if (NSResponseJSON is Array) {
					var NSCalibrations:Array = NSResponseJSON as Array;
					var newData:Boolean = false;
					myTrace("in onDownloadCalibrationsComplete, received " + NSCalibrations.length + " calibrations.");
					for(var arrayCounter:int = NSCalibrations.length - 1 ; arrayCounter >= 0; arrayCounter--) {
						var NSDownloadCalibration:Object = NSCalibrations[arrayCounter];
						if (NSDownloadCalibration.created_at) {
							if (NSDownloadCalibration.glucose) {
								var NSDownloadReadingTime:Number = DateTimeUtilities.parseDateTimeString(NSDownloadCalibration.created_at).valueOf();
								myTrace(" NSDownloadReadingTime = " + NSDownloadReadingTime);
								myTrace(" timeOfFirstCalibrationToDowload = " + timeOfFirstCalibrationToDowload);
								if (NSDownloadReadingTime >= timeOfFirstCalibrationToDowload) {
									calibrationData = new CalibrationData();
									calibrationData.glucoseLevelRaw = NSDownloadCalibration.glucose as int;
									calibrationData.realDate = NSDownloadReadingTime;
									bgReadingAndCalibrationsList.push(calibrationData);
									myTrace("in onDownloadCalibrationsComplete, with timestamp = " + calibrationData.realDate);
									myTrace("in onDownloadCalibrationsComplete, adding CalibrationData with realdate =  " + (new Date(calibrationData.realDate)).toString() + " and value = " + calibrationData.glucoseLevelRaw);
								} else {
									myTrace("in onDownloadCalibrationsComplete, ignored with realdate =  " + (new Date(NSDownloadReadingTime)).toString() + " because timestamp < " + (new Date(timeOfFirstCalibrationToDowload)).toString());
								}
							} else {
								myTrace("in onDownloadCalibrationsComplete, Nightscout has returned a reading without glucose. Ignoring!");
							}
						} else {
							myTrace("in onDownloadCalibrationsComplete, Nightscout has returned a calibration without created_at. Ignoring!");
							if (NSDownloadCalibration._id)
								myTrace("in onDownloadCalibrationsComplete, Reading ID: " + NSDownloadCalibration._id);
						}
					}
				} 
				else 
					myTrace("in onDownloadCalibrationsComplete, Nightscout response was not a JSON array. Ignoring! Response: " + response);
			} 
			catch (error:Error) 
			{
				myTrace("in onDownloadCalibrationsComplete, Error parsing Nightscout responde! Error: " + error.message + " Response: " + response);
			}
			
			processReadingsAndCalibrations();

			resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds(now, BgReading.lastNoSensor()));
		}
		
		//if return value false, it means checkLatestCalibration failed
		private static function checkLatestCalibration():Boolean {
				myTrace("in checkLatestCalibration");
				
				if (nightscoutTreatmentsURL == "") {
					myTrace("in checkLatestCalibration, nightscoutTreatmentsURL is not set. Aborting!");
					return false;
				}
				
				timeOfFirstCalibrationToDowload = 0;
				var latestCalibration:Calibration = Calibration.last();
				if (latestCalibration != null && !isNaN(latestCalibration.timestamp)) {
					timeOfFirstCalibrationToDowload = latestCalibration.timestamp;
				}
				
				var now:Number = (new Date()).valueOf();
				
				if (!NetworkInfo.networkInfo.isReachable()) {
					myTrace("in checkLatestCalibration, There's no Internet connection. Will try again later!");
					return false;
				}
				
				var parameters:URLVariables = new URLVariables();
				//don't try to download calibrations that are older than latest stored bgreading
				logstring = "Parameter list = " + "find[created_at][$gte]=" + formatter.format(Math.max(timeOfFirstBgReadingToDowload, timeOfFirstCalibrationToDowload)).replace("000+0000", "000Z") + "&find[eventType]=BG Check";
				parameters["find[created_at][$gte]"] = formatter.format(Math.max(timeOfFirstBgReadingToDowload, timeOfFirstCalibrationToDowload)).replace("000+0000", "000Z");
				parameters["find[eventType]"] = "BG Check";
				myTrace("in checkLatestCalibration, calling ns, with parameters = " + parameters.toString());
				
				waitingForNSData = true;
				lastNSDownloadAttempt = (new Date()).valueOf();
				
				NetworkConnector.createNSConnector(nightscoutTreatmentsURL + parameters.toString(), nightscoutDownloadAPISecret != "" ? nightscoutDownloadAPISecret : null, URLRequestMethod.GET, null, MODE_CALIBRATION, onDownloadCalibrationsComplete, onConnectionFailed);
				return true;
		}
		
		private static function calculateNextNSDownloadDelayInSeconds(now:Number, latestBGReading:BgReading):int {
			if (firstTime) {
				firstTime = false;
				//enforce an immediate NS Download, but wait at least 10 seconds to give time to the app to launch
				return 5; 
			} 
			
			var nextNSDownloadTimeStamp:Number = Number.NaN;
			if (latestBGReading != null) {
				nextNSDownloadTimeStamp = latestBGReading.timestamp + 5 * 60 * 1000 + 20000;//timestamp of latest stored reading + 5 minutes + 20 seconds	
				while (nextNSDownloadTimeStamp < now) {
					nextNSDownloadTimeStamp += 5 * 60 * 1000;
				}
			} else {
				nextNSDownloadTimeStamp = now + 5 * 60 * 1000;
			}
			return (nextNSDownloadTimeStamp - now)/1000;
		}
		
		/**
		 * OS device will try to reconnect, <br>
		 * bluetoothperipheral must be known already, meaning it must be a miaomiao which already had a connection in the past <br><br>
		 * If that reconnect doesn't succeed immediately (because miaomiao is not in range are already connected to another iOS device)
		 * then iOS will store internally the "wish" to connect. As soon as the MiaoMiao comes in range not connected to any other device, then it will connect<br>
		 */
		private static function reconnect(event:Event):void {
			if (isMiaoMiaoMultiple()) {
				SpikeANE.reconnectMiaoMiao();
			}
		}

		private static function commonSettingChanged(event:SettingsServiceEvent):void {
			if (event.data == CommonSettings.COMMON_SETTING_PERIPHERAL_TYPE 
				|| event.data == CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_URL
				|| event.data == CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME
				|| event.data == CommonSettings.COMMON_SETTING_API_SECRET
				|| event.data == CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_API_SECRET
				|| event.data == CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_OFFSET) {
				setupService();
			}
		}
		
		private static function localSettingChanged(event:SettingsServiceEvent):void {
			if (event.data == LocalSettings.LOCAL_SETTING_MIAOMIAO_MULTIPLE_DEVICE_ON) {
				setupService();
			}
		}
		
		private static function setupService():void {
			myTrace("in setupService");
			if (isMiaoMiaoMultiple()) {
				myTrace("in setupService and ismioamiaomultiple");
				firstTime = true;
				TransmitterService.instance.addEventListener(TransmitterServiceEvent.LAST_BGREADING_RECEIVED, bgReadingReceived);
				resetCheckReadingTimer(calculateNextNSDownloadDelayInSeconds((new Date()).valueOf(), BgReading.lastNoSensor()));
				setupNightScoutDownloadProperties();
			} else {
				myTrace("in setupService and not ismioamiaomultiple");
				if (reconnectTimer != null) {
					if (reconnectTimer.running) {
						myTrace("in setupService, reconnectTimer running, stopping it now");
						reconnectTimer.stop();
					}
				}
				if (checkReadingTimer != null) {
					if (checkReadingTimer.running) {
						myTrace("in setupService, checkReadingTimer running, stopping it now");
						checkReadingTimer.stop();
					}
				}
				TransmitterService.instance.removeEventListener(TransmitterServiceEvent.LAST_BGREADING_RECEIVED, bgReadingReceived);
			}
		}

		private static function setupNightScoutDownloadProperties():void
		{
			nightscoutDownloadURL = CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_AZURE_WEBSITE_NAME);
			nightscoutTreatmentsURL = nightscoutDownloadURL;
			if (nightscoutDownloadURL != "") {
				nightscoutDownloadURL += "/api/v1/entries/sgv.json?";
				if (nightscoutDownloadURL.indexOf('http') == -1) 
					nightscoutDownloadURL = "https://" + nightscoutDownloadURL;
			}
			if (nightscoutTreatmentsURL != "") {
				nightscoutTreatmentsURL += "/api/v1/treatments?";
				if (nightscoutTreatmentsURL.indexOf('http') == -1) 
					nightscoutTreatmentsURL = "https://" + nightscoutTreatmentsURL;
			}
			
			nightscoutDownloadOffset = Number(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_OFFSET));
			if (CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_API_SECRET) != "") {
				nightscoutDownloadAPISecret = Hex.fromArray(hash.hash(Hex.toArray(Hex.fromString(CommonSettings.getCommonSetting(CommonSettings.COMMON_SETTING_DATA_COLLECTION_NS_API_SECRET)))));
			} else {
				nightscoutDownloadAPISecret = "";
			}
		}
		
		/**
		 * true if device is miaomiao && LOCAL_SETTING_MIAOMIAO_MULTIPLE_DEVICE_ON = true
		 */
		private static function isMiaoMiaoMultiple():Boolean {
			return (LocalSettings.getLocalSetting(LocalSettings.LOCAL_SETTING_MIAOMIAO_MULTIPLE_DEVICE_ON) == "true"
				&&
				CGMBlueToothDevice.isMiaoMiao());
		}
		
		private static function getResponseAndDisposeLoader(e:Event, completeFunctionToDispose:Function, errorFunctionToDispose:Function):String {
			//Get loader
			var loader:URLLoader = e.currentTarget as URLLoader;
			
			//Get response
			var response:String = loader.data;
			
			//Dispose loader
			loader.removeEventListener(Event.COMPLETE, completeFunctionToDispose);
			loader.removeEventListener(IOErrorEvent.IO_ERROR, errorFunctionToDispose);
			loader = null;
			
			return response;
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("MultipleMiaoMiaoService.as", log);
		}
	}
}