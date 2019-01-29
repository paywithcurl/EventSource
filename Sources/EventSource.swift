
//
//  EventSource.swift
//  EventSource
//
//  Created by Andres on 2/13/15.
//  Copyright (c) 2015 Inaka. All rights reserved.
//

import Foundation

public enum EventSourceState {
    case connecting
    case open
    case closed
}

open class EventSource: NSObject, URLSessionDataDelegate {
    static let DefaultsKey = "com.inaka.eventSource.lastEventId"

    let url: URL
    fileprivate let lastEventIDKey: String
    fileprivate var onOpenCallback: (() -> Void)?
    fileprivate var onErrorCallback: ((NSError?) -> Void)?
    fileprivate var onMessageCallback: ((_ id: String?, _ event: String?, _ data: String?) -> Void)?
    fileprivate var eventListeners = Dictionary<String, (_ id: String?, _ event: String?, _ data: String?) -> Void>()
    fileprivate var headers: Dictionary<String, String>
    fileprivate var operationQueue: OperationQueue
    fileprivate var errorBeforeSetErrorCallBack: NSError?
    fileprivate let uniqueIdentifier: String
    fileprivate let validNewlineCharacters = ["\r\n", "\n", "\r"]

    open internal(set) var readyState: EventSourceState
    open fileprivate(set) var retryTime = 3000

    internal var urlSession: Foundation.URLSession?
    internal var task: URLSessionDataTask?
    internal var receivedDataBuffer: Data

    var event = Dictionary<String, String>()

    public init(url: String, headers: [String : String] = [:]) {
        self.url = URL(string: url)!
        self.headers = headers
        self.readyState = EventSourceState.closed
        self.operationQueue = OperationQueue()
        self.operationQueue.maxConcurrentOperationCount = 1
        self.receivedDataBuffer = Data()

        let port = self.url.port != nil ? String(self.url.port!) : ""
        let relativePath = self.url.relativePath
        let host = self.url.host ?? ""

        // This key must be kept the same for legacy reasons. Otherwise the stream will reconnect from the beginning.
        // TODO: Nuke this library and replace it with something sane
        self.uniqueIdentifier = "\(self.url.scheme).\(host).\(port).\(relativePath)"
        self.lastEventIDKey = "\(EventSource.DefaultsKey).\(self.uniqueIdentifier)"

        super.init()
        self.connect()
    }

//Mark: Connect

    open func connect() {
        self.receivedDataBuffer = Data()
        
        var additionalHeaders = self.headers
        if let eventID = self.lastEventID {
            additionalHeaders["Last-Event-Id"] = eventID
        }

        additionalHeaders["Accept"] = "text/event-stream"
        additionalHeaders["Cache-Control"] = "no-cache"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = TimeInterval(INT_MAX)
        configuration.timeoutIntervalForResource = TimeInterval(INT_MAX)
        configuration.httpAdditionalHeaders = additionalHeaders

        self.readyState = EventSourceState.connecting
        self.urlSession = newSession(configuration)
        self.task = urlSession!.dataTask(with: self.url)

        self.resumeSession()
    }

    internal func resumeSession() {
        self.task!.resume()
    }

    internal func newSession(_ configuration: URLSessionConfiguration) -> URLSession {
        return URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: operationQueue
        )
    }

//Mark: Close

    open func close() {
        self.readyState = EventSourceState.closed
        self.urlSession?.invalidateAndCancel()
        self.urlSession = nil
    }

    fileprivate func receivedMessageToClose(_ httpResponse: HTTPURLResponse?) -> Bool {
        guard let response = httpResponse else {
            return false
        }

        if response.statusCode == 204 {
            self.close()
            return true
        }
        return false
    }

//Mark: EventListeners

    open func onOpen(_ onOpenCallback: @escaping (() -> Void)) {
        self.onOpenCallback = onOpenCallback
    }

    open func onError(_ onErrorCallback: @escaping ((NSError?) -> Void)) {
        self.onErrorCallback = onErrorCallback

        if let errorBeforeSet = self.errorBeforeSetErrorCallBack {
            self.onErrorCallback!(errorBeforeSet)
            self.errorBeforeSetErrorCallBack = nil
        }
    }

    open func onMessage(_ onMessageCallback: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)) {
        self.onMessageCallback = onMessageCallback
    }

    open func addEventListener(_ event: String, handler: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)) {
        self.eventListeners[event] = handler
    }

    open func removeEventListener(_ event: String) -> Void {
        self.eventListeners.removeValue(forKey: event)
    }

    open func events() -> Array<String> {
        return Array(self.eventListeners.keys)
    }

//MARK: URLSessionDataDelegate

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.receivedMessageToClose(dataTask.response as? HTTPURLResponse) {
            return
        }

        if self.readyState != EventSourceState.open {
            return
        }

        self.receivedDataBuffer.append(data)
        let eventStream = extractEventsFromBuffer()
        self.parseEventStream(eventStream)
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(URLSession.ResponseDisposition.allow)

        if self.receivedMessageToClose(dataTask.response as? HTTPURLResponse) {
            return
        }

        self.readyState = EventSourceState.open
        if self.onOpenCallback != nil {
            DispatchQueue.main.async {
                self.onOpenCallback!()
            }
        }
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.readyState = EventSourceState.closed

        if self.receivedMessageToClose(task.response as? HTTPURLResponse) {
            return
        }

        guard let urlResponse = task.response as? HTTPURLResponse else {
            return
        }

        if !hasHttpError(code: urlResponse.statusCode) && (error == nil || (error! as NSError).code != -999) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(retryTime)) {
                
            }
        }

        DispatchQueue.main.async {
            var theError: NSError? = error as NSError?

            if self.hasHttpError(code: urlResponse.statusCode) {
                theError = NSError(
                        domain: "com.inaka.eventSource.error",
                        code: -1,
                        userInfo: ["message": "HTTP Status Code: \(urlResponse.statusCode)"]
                )
                self.close()
            }

            if let errorCallback = self.onErrorCallback {
                errorCallback(theError)
            } else {
                self.errorBeforeSetErrorCallBack = theError
            }
        }
    }

//MARK: Helpers

    fileprivate func extractEventsFromBuffer() -> [String] {
        var events = [String]()

        // Find first occurrence of delimiter
        var searchRange: Range<Data.Index> = 0..<self.receivedDataBuffer.count
        while let foundRange = searchForEventInRange(searchRange) {
            // Append event
            let dataChunk = receivedDataBuffer.subdata(in: searchRange.lowerBound..<foundRange.lowerBound)

            if let text = String(bytes: dataChunk, encoding: .utf8) {
                events.append(text)
            }
            // Search for next occurrence of delimiter
            searchRange = foundRange.upperBound..<searchRange.upperBound
        }

        let rangeToReplace = 0..<searchRange.lowerBound
        // Remove the found events from the buffer
        self.receivedDataBuffer.replaceSubrange(rangeToReplace, with: [])

        return events
    }

    fileprivate func searchForEventInRange(_ searchRange: Range<Data.Index>) -> Range<Data.Index>? {
        let delimiters = validNewlineCharacters.map { "\($0)\($0)".data(using: String.Encoding.utf8)! }

        for delimiter in delimiters {
            let foundRange = receivedDataBuffer.range(of: delimiter, in: searchRange)

            if foundRange != nil {
                return foundRange
            }
        }

        return nil
    }

    fileprivate func parseEventStream(_ events: [String]) {
        var parsedEvents: [(id: String?, event: String?, data: String?)] = Array()

        for event in events {
            if event.isEmpty {
                continue
            }

            if event.hasPrefix(":") {
                continue
            }

            if (event as NSString).contains("retry:") {
                if let reconnectTime = parseRetryTime(event) {
                    self.retryTime = reconnectTime
                }
                continue
            }

            parsedEvents.append(parseEvent(event))
        }

        for parsedEvent in parsedEvents {
            self.lastEventID = parsedEvent.id

            if parsedEvent.event == nil {
                if let data = parsedEvent.data, let onMessage = self.onMessageCallback {
                    DispatchQueue.main.async {
                        onMessage(parsedEvent.id, "message", data)
                    }
                }
            }

            if let event = parsedEvent.event, let data = parsedEvent.data, let eventHandler = self.eventListeners[event] {
                DispatchQueue.main.async {
                    eventHandler(parsedEvent.id, event, data)
                }
            }
        }
    }

    internal var lastEventID: String? {
        set {
            if let lastEventID = newValue {
                let defaults = UserDefaults.standard
                defaults.set(lastEventID, forKey: lastEventIDKey)
                defaults.synchronize()
            }
        }

        get {
            let defaults = UserDefaults.standard

            if let lastEventID = defaults.string(forKey: lastEventIDKey) {
                return lastEventID
            }
            return nil
        }
    }

    fileprivate func parseEvent(_ eventString: String) -> (id: String?, event: String?, data: String?) {
        var event = Dictionary<String, String>()

        for line in eventString.components(separatedBy: CharacterSet.newlines) as [String] {
            autoreleasepool {
                let (k, value) = self.parseKeyValuePair(line)
                guard let key = k else { return }

                if let value = value {
                    if event[key] != nil {
                        event[key] = "\(event[key]!)\n\(value)"
                    } else {
                        event[key] = value
                    }
                } else if value == nil {
                    event[key] = ""
                }
            }
        }

        return (event["id"], event["event"], event["data"])
    }

    fileprivate func parseKeyValuePair(_ line: String) -> (String?, String?) {
        var key: NSString?, value: NSString?
        let scanner = Scanner(string: line)
        scanner.scanUpTo(":", into: &key)
        scanner.scanString(":", into: nil)

        for newline in validNewlineCharacters {
            if scanner.scanUpTo(newline, into: &value) {
                break
            }
        }

        return (key as String?, value as String?)
    }

    fileprivate func parseRetryTime(_ eventString: String) -> Int? {
        var reconnectTime: Int?
        let separators = CharacterSet(charactersIn: ":")
        if let milli = eventString.components(separatedBy: separators).last {
            let milliseconds = trim(milli)

            if let intMiliseconds = Int(milliseconds) {
                reconnectTime = intMiliseconds
            }
        }
        return reconnectTime
    }

    fileprivate func trim(_ string: String) -> String {
        return string.trimmingCharacters(in: CharacterSet.whitespaces)
    }

    fileprivate func hasHttpError(code: Int) -> Bool {
        return code >= 400
    }

    class open func basicAuth(_ username: String, password: String) -> String {
        let authString = "\(username):\(password)"
        let authData = authString.data(using: String.Encoding.utf8)
        let base64String = authData!.base64EncodedString(options: [])

        return "Basic \(base64String)"
    }
}
