//
//  SpotifyIdleInfo.swift
//  MTMR
//
//  What the Spotify widget shows while Spotify is not running: clock, battery, weather, CPU & RAM.
//  No account or API key: battery is IOKit, weather is Open-Meteo (needs the Location permission).
//

import Cocoa
import CoreLocation
import IOKit.ps

struct IdleLine: Equatable {
    let id: String
    let text: String
    let symbol: String
}

final class IdleInfoProvider: NSObject, CLLocationManagerDelegate {
    static let shared = IdleInfoProvider()
    /// Canonical order, also the order of the rotation.
    static let allIds = ["clock", "battery", "weather", "system"]

    func lines(for ids: [String]) -> [IdleLine] {
        Self.allIds.filter { ids.contains($0) }.compactMap { line(for: $0) }
    }

    private func line(for id: String) -> IdleLine? {
        switch id {
        case "clock": return clockLine()
        case "battery": return batteryLine()
        case "weather": return weatherLineIfAvailable()
        case "system": return systemLine()
        default: return nil
        }
    }

    // MARK: clock

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func clockLine() -> IdleLine {
        let now = Date()
        return IdleLine(id: "clock", text: "\(dayFormatter.string(from: now))   \(timeFormatter.string(from: now))", symbol: "clock")
    }

    // MARK: battery

    private var batteryCache: (line: IdleLine?, at: Date)?

    private func batteryLine() -> IdleLine? {
        if let c = batteryCache, Date().timeIntervalSince(c.at) < 20 { return c.line }
        let line = readBattery()
        batteryCache = (line, Date())
        return line
    }

    private func readBattery() -> IdleLine? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let percent = current * 100 / maximum
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            func duration(_ minutes: Int?) -> String? {
                guard let m = minutes, m > 0 else { return nil }
                return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
            }
            var text = "\(percent)%"
            if charging {
                text += "   Charging" + (duration(d[kIOPSTimeToFullChargeKey] as? Int).map { " · \($0) to full" } ?? "")
            } else if onAC {
                text += "   Plugged in"
            } else if let left = duration(d[kIOPSTimeToEmptyKey] as? Int) {
                text += "   \(left) left"
            }
            let symbol: String
            switch percent {
            case _ where charging: symbol = "bolt.fill"
            case 88...: symbol = "battery.100"
            case 63...: symbol = "battery.75"
            case 38...: symbol = "battery.50"
            case 13...: symbol = "battery.25"
            default: symbol = "battery.0"
            }
            return IdleLine(id: "battery", text: text, symbol: symbol)
        }
        return nil // desktop Mac without a battery
    }

    // MARK: CPU & RAM

    private var systemCache: (line: IdleLine, at: Date)?

    private func systemLine() -> IdleLine {
        if let c = systemCache, Date().timeIntervalSince(c.at) < 5 { return c.line } // sampled slowly: the line should not keep sliding
        let cpu = 100 - CPU.systemUsage().idle
        let cpuText = cpu.isFinite ? String(format: "CPU %.0f%%", cpu) : "CPU –"
        let ramText = SystemStats.memoryUsedPercent().map { String(format: "RAM %.0f%%", $0) } ?? "RAM –"
        let line = IdleLine(id: "system", text: "\(cpuText)   \(ramText)", symbol: "cpu")
        systemCache = (line, Date())
        return line
    }

    // MARK: weather (Open-Meteo, no key)

    private var weather: IdleLine?
    private var weatherFetchedAt = Date.distantPast
    private var weatherBusy = false
    private var location: CLLocation?
    private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer // a city is enough
        return m
    }()

    private func weatherLineIfAvailable() -> IdleLine? {
        refreshWeatherIfNeeded()
        return weather
    }

    private func refreshWeatherIfNeeded() {
        guard !weatherBusy, Date().timeIntervalSince(weatherFetchedAt) > 15 * 60 else { return }
        let status = locationManager.authorizationStatus
        guard status != .denied, status != .restricted else { return } // no permission: the weather item simply stays out of the rotation
        weatherBusy = true
        weatherFetchedAt = Date() // also throttles retries after a failure
        if let location = location, Date().timeIntervalSince(location.timestamp) < 3600 {
            fetchWeather(at: location)
        } else {
            locationManager.requestLocation()
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { weatherBusy = false; return }
        location = loc
        fetchWeather(at: loc)
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        weatherBusy = false
    }

    private func fetchWeather(at loc: CLLocation) {
        let fahrenheit = !Locale.current.usesMetricSystem
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", loc.coordinate.latitude)), // rounded: a city, not a street
            .init(name: "longitude", value: String(format: "%.2f", loc.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var line: IdleLine?
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cur = json["current"] as? [String: Any],
               let temp = cur["temperature_2m"] as? Double,
               let code = cur["weather_code"] as? Int {
                let (symbol, label) = Self.describe(code: code, isDay: (cur["is_day"] as? Int ?? 1) == 1)
                line = IdleLine(id: "weather", text: "\(Int(temp.rounded()))°\(fahrenheit ? "F" : "C")   \(label)", symbol: symbol)
            }
            DispatchQueue.main.async {
                if let line = line { self?.weather = line }
                self?.weatherBusy = false
            }
        }.resume()
    }

    /// WMO weather interpretation code -> SF Symbol and a short label.
    private static func describe(code: Int, isDay: Bool) -> (String, String) {
        switch code {
        case 0: return (isDay ? "sun.max" : "moon.stars", "Clear")
        case 1, 2: return (isDay ? "cloud.sun" : "cloud.moon", "Partly cloudy")
        case 3: return ("cloud", "Overcast")
        case 45, 48: return ("cloud.fog", "Fog")
        case 51...57: return ("cloud.drizzle", "Drizzle")
        case 61...65: return ("cloud.rain", "Rain")
        case 66, 67: return ("cloud.sleet", "Freezing rain")
        case 71...75, 77: return ("snowflake", "Snow")
        case 80...82: return ("cloud.heavyrain", "Showers")
        case 85, 86: return ("cloud.snow", "Snow showers")
        case 95...99: return ("cloud.bolt.rain", "Thunderstorm")
        default: return ("cloud", "Weather")
        }
    }
}
