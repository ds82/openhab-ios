//  Converted to Swift 4 by Swiftify v4.2.20229 - https://objectivec2swift.com/
//
//  OpenHABSitemapPage.swift
//  HelloRestKit
//
//  Created by Victor Belov on 10/01/14.
//  Copyright (c) 2014 Victor Belov. All rights reserved.
//
//  Converted to Swift 4 by Tim Müller-Seydlitz and Swiftify on 06/01/18
//

import Foundation
import os.log

extension OpenHABSitemapPage {

    struct CodingData: Decodable {
        let pageId: String?
        let title: String?
        let link: String?
        let leaf: Bool?
        let widgets: [OpenHABWidget.CodingData]?

        private enum CodingKeys: String, CodingKey {
            case pageId = "id"
            case title
            case link
            case leaf
            case widgets
        }
    }
}

extension OpenHABSitemapPage.CodingData {
    var openHABSitemapPage: OpenHABSitemapPage {
        let mappedWidgets = self.widgets?.map { $0.openHABWidget } ?? []
        return OpenHABSitemapPage(pageId: self.pageId ?? "", title: self.title ?? "", link: self.link ?? "", leaf: self.leaf ?? false, widgets: mappedWidgets)
    }
}

@objcMembers class OpenHABSitemapPage: NSObject {
    var sendCommand: ((_ item: OpenHABItem, _ command: String?) -> Void)?
    var widgets: [OpenHABWidget] = []
    var pageId = ""
    var title = ""
    var link = ""
    var leaf = false

    init(pageId: String, title: String, link: String, leaf: Bool, widgets: [OpenHABWidget]) {
        super.init()
        self.pageId = pageId
        self.title = title
        self.link = link
        self.leaf = leaf
        var ws: [OpenHABWidget] = []
        // This could be expressed recursively but this does the job on 2 levels 
        for w1 in widgets {
            ws.append(w1)
            for w2 in w1.widgets {
                ws.append(w2)
            }
        }
        self.widgets = ws
        self.widgets.forEach {
            $0.sendCommand = { [weak self] (item, command) in
                self?.sendCommand(item, commandToSend: command)
            }
        }
    }

    init(xml xmlElement: GDataXMLElement?) {
        let propertyNamesString: Set =  ["pageId", "title", "link"]
        let propertyNamesBool: Set = ["leaf"]
        super.init()
        for child in (xmlElement?.children())! {
            if let child = child as? GDataXMLElement {
                if !(child.name() == "widget") {
                    if !(child.name() == "id") {
                        if let name = child.name() {
                            let value = child.stringValue() ?? ""
                            if propertyNamesString.contains(name) {
                                setValue(value, forKey: name)
                            }
                            if propertyNamesBool.contains(name) {
                                setValue(value == "true" ? true : false, forKey: name)
                            }
                        }
                    } else {
                        pageId = child.stringValue() ?? ""
                    }
                } else {
                    let newWidget = OpenHABWidget(xml: child)
                    widgets.append(newWidget)
                }
            }
        }
        var ws: [OpenHABWidget] = []
        // This could be expressed recursively but this does the job on 2 levels
        for w1 in widgets {
            ws.append(w1)
            for w2 in w1.widgets {
                ws.append(w2)
            }
        }
        self.widgets = ws
        self.widgets.forEach {
            $0.sendCommand = { [weak self] (item, command) in
                self?.sendCommand(item, commandToSend: command)
            }
        }
    }

    private func sendCommand(_ item: OpenHABItem?, commandToSend command: String?) {
        guard let item = item else { return }

        os_log("SitemapPage sending command %{PUBLIC}@ to %{PUBLIC}@", log: OSLog.remoteAccess, type: .info, command ?? "", item.name)
        sendCommand?(item, command)
    }

    init(pageId: String, title: String, link: String, leaf: Bool, expandedWidgets: [OpenHABWidget]) {
        super.init()
        self.pageId = pageId
        self.title = title
        self.link = link
        self.leaf = leaf
        self.widgets = expandedWidgets
        self.widgets.forEach {
            $0.sendCommand = { [weak self] (item, command) in
                self?.sendCommand(item, commandToSend: command)
            }

        }
    }
}

extension OpenHABSitemapPage {
    func filter (_ isIncluded: (OpenHABWidget) throws -> Bool) rethrows -> OpenHABSitemapPage {
        let filteredOpenHABSitemapPage = OpenHABSitemapPage(pageId: self.pageId,
                                  title: self.title,
                                  link: self.link,
                                  leaf: self.leaf,
                                  expandedWidgets: try self.widgets.filter(isIncluded))
        return filteredOpenHABSitemapPage
    }
}
