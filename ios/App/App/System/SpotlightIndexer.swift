import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Puts album titles, artists and genres into this device's Spotlight index, so a record
/// can be opened from system search. Opt-in from Settings; the index never leaves the device.
final class SpotlightIndexer {
    static let domainIdentifier = "app.isolation.albums"
    static let itemPrefix = "album:"
    private static let signatureKey = "aeon.spotlight.signature"

    private let catalog: CatalogRepository
    private let index: CSSearchableIndex
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "app.aeon.spotlight", qos: .utility)
    private var enabled = false
    private var pending: DispatchWorkItem?
    private var observation: CatalogObservation?

    init(catalog: CatalogRepository, index: CSSearchableIndex = .default(), defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.index = index
        self.defaults = defaults
    }

    deinit { observation?.cancel() }

    /// Album ID for a Spotlight continuation, or nil when the activity is not one of ours.
    static func albumID(fromItemIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(itemPrefix) else { return nil }
        let id = String(identifier.dropFirst(itemPrefix.count))
        return id.isEmpty ? nil : id
    }

    func setEnabled(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.enabled != value else { return }
            self.enabled = value
            if value {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.observation = self.catalog.observeLibrary { [weak self] _ in self?.scheduleRefresh() }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.observation?.cancel()
                    self?.observation = nil
                }
                self.pending?.cancel()
                self.defaults.removeObject(forKey: Self.signatureKey)
                self.index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in }
            }
        }
    }

    /// Imports publish many catalogue changes in a burst; index once they settle.
    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshIfChanged() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    private func refreshIfChanged() {
        guard enabled, let signature = try? catalog.albumCatalogueSignature(),
              signature != defaults.string(forKey: Self.signatureKey) else { return }
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { [weak self] _ in
            self?.queue.async { self?.indexAll(signature: signature) }
        }
    }

    private func indexAll(signature: String) {
        let pageSize = CatalogDatabase.maximumPageSize
        var offset = 0
        while enabled, let page = try? catalog.albumPage(offset: offset, limit: pageSize, sort: .recentlyAdded), !page.isEmpty {
            let items = page.map { album -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .audio)
                attributes.title = album.title
                attributes.displayName = album.title
                attributes.contentDescription = [album.artist, album.year, album.genre]
                    .filter { !$0.isEmpty }.joined(separator: " \u{00b7} ")
                attributes.keywords = [album.artist, album.genre].filter { !$0.isEmpty }
                return CSSearchableItem(
                    uniqueIdentifier: Self.itemPrefix + album.id,
                    domainIdentifier: Self.domainIdentifier,
                    attributeSet: attributes
                )
            }
            index.indexSearchableItems(items) { _ in }
            offset += page.count
            if page.count < pageSize { break }
        }
        if enabled { defaults.set(signature, forKey: Self.signatureKey) }
    }
}
