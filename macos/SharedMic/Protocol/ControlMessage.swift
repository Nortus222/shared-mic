import Foundation

/// protocol-v1 §4: fixed for version 1, no negotiation is possible.
public struct AudioFormat: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let sampleFormat: String

    public init(sampleRate: Int, channels: Int, sampleFormat: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
    }

    public static let v1 = AudioFormat(
        sampleRate: SharedMicProtocol.sampleRate,
        channels: SharedMicProtocol.channels,
        sampleFormat: SharedMicProtocol.sampleFormat
    )

    public var jsonObject: [String: Any] {
        ["sampleRate": sampleRate, "channels": channels, "sampleFormat": sampleFormat]
    }
}

/// The eleven control message types of protocol-v1 §5.
public enum ControlMessage: Equatable {
    case greeting(serverId: String, nonce: String)
    case hello(clientId: String, mac: String)
    case helloAck(serverId: String, micPresent: Bool, deviceLabel: String)
    case start(requestId: String, preferredFormat: AudioFormat)
    case startAck(requestId: String, sessionId: String, format: AudioFormat)
    case startNack(requestId: String, reason: String)
    case stop(requestId: String, sessionId: String)
    case stopAck(requestId: String, sessionId: String)
    case status(micPresent: Bool, active: Bool, deviceLabel: String)
    case ping(seq: Int)
    case pong(seq: Int)

    public var typeName: String {
        switch self {
        case .greeting: return "GREETING"
        case .hello: return "HELLO"
        case .helloAck: return "HELLO_ACK"
        case .start: return "START"
        case .startAck: return "START_ACK"
        case .startNack: return "START_NACK"
        case .stop: return "STOP"
        case .stopAck: return "STOP_ACK"
        case .status: return "STATUS"
        case .ping: return "PING"
        case .pong: return "PONG"
        }
    }

    public static let allTypeNames: Set<String> = [
        "GREETING", "HELLO", "HELLO_ACK", "START", "START_ACK", "START_NACK",
        "STOP", "STOP_ACK", "STATUS", "PING", "PONG"
    ]

    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["v": SharedMicProtocol.version, "type": typeName]
        switch self {
        case .greeting(let serverId, let nonce):
            object["serverId"] = serverId
            object["nonce"] = nonce
        case .hello(let clientId, let mac):
            object["clientId"] = clientId
            object["mac"] = mac
        case .helloAck(let serverId, let micPresent, let deviceLabel):
            object["serverId"] = serverId
            object["micPresent"] = micPresent
            object["deviceLabel"] = deviceLabel
        case .start(let requestId, let preferredFormat):
            object["requestId"] = requestId
            object["preferredFormat"] = preferredFormat.jsonObject
        case .startAck(let requestId, let sessionId, let format):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
            object["format"] = format.jsonObject
        case .startNack(let requestId, let reason):
            object["requestId"] = requestId
            object["reason"] = reason
        case .stop(let requestId, let sessionId):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
        case .stopAck(let requestId, let sessionId):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
        case .status(let micPresent, let active, let deviceLabel):
            object["micPresent"] = micPresent
            object["active"] = active
            object["deviceLabel"] = deviceLabel
        case .ping(let seq):
            object["seq"] = seq
        case .pong(let seq):
            object["seq"] = seq
        }
        return object
    }

    public init(jsonObject: Any) throws {
        guard let dictionary = jsonObject as? [String: Any] else {
            throw ProtocolError.notAnObject
        }
        guard let typeName = dictionary["type"] as? String,
              ControlMessage.allTypeNames.contains(typeName) else {
            throw ProtocolError.unknownControlType((dictionary["type"] as? String) ?? "<missing>")
        }
        // protocol-v1 §1: a "v" other than 1 is a hard protocol violation.
        let rawVersion = dictionary["v"] as? Int
        guard rawVersion == SharedMicProtocol.version else {
            throw ProtocolError.unsupportedVersion(rawVersion)
        }

        func string(_ key: String) throws -> String {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let value = raw as? String else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return value
        }
        func bool(_ key: String) throws -> Bool {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let value = raw as? Bool else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return value
        }
        func integer(_ key: String) throws -> Int {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            // JSONSerialization hands back NSNumber for every JSON number. It also
            // hands back NSNumber for `true`/`false`, which this deliberately does
            // not try to separate — the reference Python decoder does not type-check
            // these fields at all, and inventing a stricter rule here would reject
            // messages the far end considers valid.
            guard let number = raw as? NSNumber else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return number.intValue
        }
        func format(_ key: String) throws -> AudioFormat {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let nested = raw as? [String: Any],
                  let sampleRate = (nested["sampleRate"] as? NSNumber)?.intValue,
                  let channels = (nested["channels"] as? NSNumber)?.intValue,
                  let sampleFormat = nested["sampleFormat"] as? String else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return AudioFormat(sampleRate: sampleRate, channels: channels, sampleFormat: sampleFormat)
        }

        switch typeName {
        case "GREETING":
            self = .greeting(serverId: try string("serverId"), nonce: try string("nonce"))
        case "HELLO":
            self = .hello(clientId: try string("clientId"), mac: try string("mac"))
        case "HELLO_ACK":
            self = .helloAck(serverId: try string("serverId"),
                             micPresent: try bool("micPresent"),
                             deviceLabel: try string("deviceLabel"))
        case "START":
            self = .start(requestId: try string("requestId"),
                          preferredFormat: try format("preferredFormat"))
        case "START_ACK":
            self = .startAck(requestId: try string("requestId"),
                             sessionId: try string("sessionId"),
                             format: try format("format"))
        case "START_NACK":
            self = .startNack(requestId: try string("requestId"), reason: try string("reason"))
        case "STOP":
            self = .stop(requestId: try string("requestId"), sessionId: try string("sessionId"))
        case "STOP_ACK":
            self = .stopAck(requestId: try string("requestId"), sessionId: try string("sessionId"))
        case "STATUS":
            self = .status(micPresent: try bool("micPresent"),
                           active: try bool("active"),
                           deviceLabel: try string("deviceLabel"))
        case "PING":
            self = .ping(seq: try integer("seq"))
        case "PONG":
            self = .pong(seq: try integer("seq"))
        default:
            throw ProtocolError.unknownControlType(typeName)
        }
    }
}
