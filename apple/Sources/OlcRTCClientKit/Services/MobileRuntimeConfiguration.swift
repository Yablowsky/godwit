#if canImport(Mobile)
@preconcurrency import Mobile

enum MobileRuntimeConfiguration {
    static func apply(_ options: OlcRTCStartOptions, to runtime: MobileRuntime) throws {
        try runtime.setProvider(options.carrierName)
        try runtime.setTransport(options.transportName)
        try runtime.setRoom(options.roomID)
        runtime.setDeviceID(options.clientID)
        try runtime.setKey(options.keyHex)
        try runtime.setSocksListenHost("127.0.0.1")
        try runtime.setSocksPort(options.socksPort)
        try runtime.setSocksCredentials(options.socksUser, password: options.socksPass)
        if !options.dnsServer.isEmpty {
            try runtime.setDNS(options.dnsServer)
        }
        runtime.setDebug(options.debugLogging)

        switch options.transportName {
        case "vp8channel":
            try runtime.setVP8Options(options.vp8FPS, batchSize: options.vp8BatchSize)
        case "seichannel":
            try runtime.setSEIOptions(
                options.seiFPS, batchSize: options.seiBatchSize,
                fragmentSize: options.seiFragmentSize, ackTimeoutMillis: options.seiAckTimeoutMillis
            )
        case "videochannel":
            try runtime.setVideoOptions(
                options.videoWidth, height: options.videoHeight, fps: options.videoFPS,
                qrSize: options.videoQRSize, qrRecovery: options.videoQRRecovery,
                codec: options.videoCodec, tileModule: options.videoTileModule, tileRS: options.videoTileRS
            )
        default:
            break
        }
    }
}
#endif
