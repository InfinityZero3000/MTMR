//
//  WeatherBarItem.swift
//  MTMR
//
//  Created by Daniel Apatin on 18.04.2018.
//  Copyright © 2018 Anton Palgunov. All rights reserved.
//

import Cocoa
import CoreLocation

class WeatherBarItem: CustomButtonTouchBarItem, CLLocationManagerDelegate {
    private let activity: NSBackgroundActivityScheduler
    private var units: String
    private var api_key: String
    private var units_str = "°F"
    private var prev_location: CLLocation!
    private var location: CLLocation!
    // SF Symbols per OpenWeather icon code (used for icon_type "images").
    private let iconsImages = [
        "01d": "sun.max", "01n": "moon.stars", "02d": "cloud.sun", "02n": "cloud.moon", "03d": "cloud", "03n": "cloud",
        "04d": "cloud", "04n": "cloud", "09d": "cloud.drizzle", "09n": "cloud.drizzle", "10d": "cloud.sun.rain", "10n": "cloud.moon.rain",
        "11d": "cloud.bolt.rain", "11n": "cloud.bolt.rain", "13d": "snowflake", "13n": "snowflake", "50d": "cloud.fog", "50n": "cloud.fog",
    ]
    private let iconsText = ["01d": "☀", "01n": "☀", "02d": "☁", "02n": "☁", "03d": "☁", "03n": "☁", "04d": "☁", "04n": "☁", "09d": "☂", "09n": "☂", "10d": "☂", "10n": "☂", "11d": "☈", "11n": "☈", "13d": "☃", "13n": "☃", "50d": "♨", "50n": "♨"]
    private var iconsSource: Dictionary<String, String>
    private let useSymbols: Bool

    private var manager: CLLocationManager!

    init(identifier: NSTouchBarItem.Identifier, interval: TimeInterval, units: String, api_key: String, icon_type: String? = "text") {
        activity = NSBackgroundActivityScheduler(identifier: "\(identifier.rawValue).updatecheck")
        activity.interval = interval
        self.units = units
        self.api_key = api_key

        if self.units == "metric" {
            units_str = "°C"
        }

        if self.units == "imperial" {
            units_str = "°F"
        }

        useSymbols = icon_type == "images"
        if icon_type == "images" {
            iconsSource = iconsImages
        } else {
            iconsSource = iconsText
        }

        super.init(identifier: identifier, attributedTitle: .loading)

        let status = CLLocationManager().authorizationStatus
        if status == .restricted || status == .denied {
            print("User permission not given")
            return
        }

        if !CLLocationManager.locationServicesEnabled() {
            print("Location services not enabled")
            return
        }

        activity.repeats = true
        activity.qualityOfService = .utility
        activity.schedule { (completion: NSBackgroundActivityScheduler.CompletionHandler) in
            self.updateWeather()
            completion(NSBackgroundActivityScheduler.Result.finished)
        }
        updateWeather()

        manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.startUpdatingLocation()
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func updateWeather() {
        if location != nil {
            let urlRequest = URLRequest(url: URL(string: "https://api.openweathermap.org/data/2.5/weather?lat=\(location.coordinate.latitude)&lon=\(location.coordinate.longitude)&units=\(units)&appid=\(api_key)")!)

            let task = URLSession.shared.dataTask(with: urlRequest) { data, _, error in

                if error == nil {
                    do {
                        let json = try JSONSerialization.jsonObject(with: data!, options: .mutableContainers) as! [String: AnyObject]
//                        print(json)
                        var temperature: Int!
                        var condition_icon = ""

                        if let main = json["main"] as? [String: AnyObject] {
                            if let temp = main["temp"] as? Double {
                                temperature = Int(temp)
                            }
                        }

                        if let weather = json["weather"] as? NSArray, let item = weather[0] as? NSDictionary {
                            let icon = item["icon"] as! String
                            if let test = self.iconsSource[icon] {
                                condition_icon = test
                            }
                        }

                        if temperature != nil {
                            DispatchQueue.main.async {
                                self.setWeather(icon: condition_icon, text: "\(temperature!)\(self.units_str)")
                            }
                        }
                    } catch let jsonError {
                        print(jsonError.localizedDescription)
                    }
                }
            }

            task.resume()
        }
    }

    func setWeather(icon: String, text: String) {
        if useSymbols, !icon.isEmpty {
            attributedTitle = .symbolText(icon, text)
        } else {
            title = "\(icon) \(text)"
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let lastLocation = locations.last!
        location = lastLocation
        if prev_location == nil {
            updateWeather()
        }
        prev_location = lastLocation
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        print(error)
    }

    func locationManager(_: CLLocationManager, didChangeAuthorization _: CLAuthorizationStatus) {
//        print("inside didChangeAuthorization ");
        updateWeather()
    }
    
    deinit {
        activity.invalidate()
    }
}
