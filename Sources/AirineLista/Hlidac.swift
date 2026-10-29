import CoreServices
import Foundation

/// FSEvents nad vybranými složkami. Nic neprochází, jen sbírá cesty, které
/// macOS ohlásí, a po zklidnění (editory ukládají víckrát za sebou) je předá
/// dál najednou. Běží na vlastní frontě; `predej` volá na hlavním vlákně.
final class Hlidac: @unchecked Sendable {
    /// Ticho po poslední události, než se dávka předá.
    static let zklidneni: TimeInterval = 5

    private var stream: FSEventStreamRef?
    private let fronta = DispatchQueue(label: "eu.airine.hlidac", qos: .utility)
    private var cesty = Set<String>()
    private var vse = false
    private var odklad: DispatchWorkItem?
    private let predej: @MainActor (Set<String>, Bool) -> Void

    /// `predej(cesty, vse)`: `vse` = macOS události sloučil a je potřeba
    /// porovnat celé složky (příznak MustScanSubDirs).
    init(slozky: [String], predej: @escaping @MainActor (Set<String>, Bool) -> Void) {
        self.predej = predej
        guard !slozky.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let zpetne: FSEventStreamCallback = { _, info, pocet, cesty, priznaky, _ in
            guard let info else { return }
            let h = Unmanaged<Hlidac>.fromOpaque(info).takeUnretainedValue()
            let pole = (unsafeBitCast(cesty, to: NSArray.self) as? [String]) ?? []
            let p = UnsafeBufferPointer(start: priznaky, count: pocet)
            h.prijmi(pole, vse: p.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 })
        }
        let volby = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, zpetne, &ctx, slozky as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, volby)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, fronta)
        FSEventStreamStart(stream)
    }

    func zastav() {
        fronta.sync {
            odklad?.cancel()
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func prijmi(_ nove: [String], vse: Bool) {
        // Jen MD soubory a cesty bez přípony (smazaná nebo přesunutá složka).
        for c in nove {
            let pripona = (c as NSString).pathExtension.lowercased()
            if ["md", "mdc"].contains(pripona) || pripona.isEmpty { cesty.insert(c) }
        }
        self.vse = self.vse || vse
        guard !cesty.isEmpty || self.vse else { return }
        odklad?.cancel()
        let d = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let davka = self.cesty, vse = self.vse
            self.cesty = []; self.vse = false
            Task { @MainActor in self.predej(davka, vse) }
        }
        odklad = d
        fronta.asyncAfter(deadline: .now() + Self.zklidneni, execute: d)
    }
}
