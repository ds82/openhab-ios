//  Converted to Swift 4 by Swiftify v4.2.20229 - https://objectivec2swift.com/
//
//  OpenHABItem.swift
//  HelloRestKit
//
//  Created by Victor Belov on 10/01/14.
//  Copyright (c) 2014 Victor Belov. All rights reserved.
//
//  Converted to Swift 4 by Tim Müller-Seydlitz and Swiftify on 06/01/18
//
import CoreLocation
import os.log
import UIKit

extension OpenHABItem {

    struct CodingData: Decodable {
        let type: String
        let groupType: String?
        let name: String
        let link: String
        let state: String
        let label: String?
    }
}

extension OpenHABItem.CodingData {
    var openHABItem: OpenHABItem {
        return OpenHABItem(name: self.name, type: self.type, state: self.state, link: self.link, label: self.label, groupType: self.groupType)
    }
}

@objcMembers final class OpenHABItem: NSObject {
    var type = ""
    var groupType = ""
    var name = ""
    var state = ""
    var link = ""
    var label = ""

    init(name: String, type: String, state: String, link: String, label: String?, groupType: String?) {
        self.name = name
        self.type = type
        self.state = state
        self.link = link
        self.label = label ?? ""
        self.groupType = groupType ?? ""
    }

    init(xml xmlElement: GDataXMLElement?) {
        let propertyNames: Set = ["name", "type", "groupType", "state", "link" ]
        super.init()
        for child in (xmlElement?.children())! {
            if let child = child as? GDataXMLElement {
                if let name = child.name() {
                    if propertyNames.contains(name) {
                        setValue(child.stringValue(), forKey: child.name() ?? "")
                    }
                }
            }
        }
    }

    func stateAsDouble() -> Double {
        return state.numberValue?.doubleValue ?? 0
    }

    func stateAsInt() -> Int {
        return state.numberValue?.intValue ?? 0
    }

    func stateAsUIColor() -> UIColor? {
        if state == "Uninitialized" {
            return UIColor(hue: 0, saturation: 0, brightness: 0, alpha: 1.0)
        } else {
            let values = state.components(separatedBy: ",")
            if values.count == 3 {
                let hue = CGFloat((Float(values[0]) ?? 0.0)/360)
                let saturation = CGFloat((Float(values[1]) ?? 0.0)/100)
                let brightness = CGFloat((Float(values[2]) ?? 0.0)/100)
                os_log("hue saturation brightness: %g %g %g", log: .default, type: .info, hue, saturation, brightness)
                return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
            } else {
                return UIColor(hue: 0, saturation: 0, brightness: 0, alpha: 1.0)
            }
        }
    }

    func stateAsLocation() -> CLLocation? {
        if type == "Location" {
            // Example of `state` string for location: '0.000000,0.000000,0.0' ('<latitude>,<longitued>,<altitude>')
            let locationComponents = state.components(separatedBy: ",")
            if locationComponents.count >= 2 {
                let latitude = CLLocationDegrees(Double(locationComponents[0]) ?? 0.0)
                let longitude = CLLocationDegrees(Double(locationComponents[1]) ?? 0.0)

                return CLLocation(latitude: latitude, longitude: longitude)
            }
        }
        return nil
    }
}
