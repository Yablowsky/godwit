#if canImport(Mobile)
@preconcurrency import Mobile

enum LegacyMobileConfiguration {
    static func validate(_ options: OlcRTCStartOptions) throws {
        guard ["vp8channel", "datachannel"].contains(options.transportName) else {
            throw OlcRTCEngineError.unsupportedOption(
                "Legacy mobile core supports only VP8 and datachannel. Choose a compatible profile.")
        }
    }

    static func apply(_ options: OlcRTCStartOptions) throws {
        try validate(options)
        MobileSetProviders()
        MobileSetTransport(options.transportName)
        MobileSetSocksListenHost("127.0.0.1")
        // Reset defaults on EVERY start: legacy settings are global and survive Stop.
        MobileSetDNS(options.dnsServer.isEmpty ? "8.8.8.8:53" : options.dnsServer)
        MobileSetDebug(options.debugLogging)
        MobileSetVP8Options(options.vp8FPS, options.vp8BatchSize)
        MobileSetLivenessOptions(0, 0, 0)
    }
}
#endif
