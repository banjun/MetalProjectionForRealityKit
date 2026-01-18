import RealityKit
import DMX
import Foundation

public protocol DMXHolderType {
    var dmx: DMX? { get }
}

public struct DMXHolderComponent: Component {
    var dmxHolder: any DMXHolderType
}

public final class DMXHolder: DMXHolderType {
    public let sink: FastSink
    public let universe: UInt16
    public var dmx: DMX? {sink.payloads[UInt16BE(integerLiteral: universe)]?.dmx}
    @MainActor public let multipeer = Multipeer()
    @MainActor public init(port: UInt16 = ACN_SDT_MULTICAST_PORT, universe: UInt16, interval: Duration = .milliseconds(1000 / 60)) {
        self.universe = universe
        self.sink = .init(port: port, interval: interval)
    }
    public func start() {
        sink.start(universe: universe)
        sink.subscribeMultipeer(multipeer.receivedData)
        multipeer.start()
    }
    public func stop() {
        sink.unsubscribeMultipper()
        multipeer.stop()
        sink.stop(universe: universe)
    }
}
