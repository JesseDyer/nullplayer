import Foundation

/// The YouTube source: subscribed channels on the Radio tab slot, a channel search on Search.
extension LibraryBrowserModel {

    func loadYouTubeChannels() {
        isLoading = false
        errorMessage = nil
        buildYouTubeChannelItems()
        YouTubeManager.shared.backfillMissingAvatars()
    }

    var youtubeRows: YouTubeRowBuilder {
        YouTubeRowBuilder(expanded: Set(expandedYouTubeChannels.keys),
                          uploads: YouTubeChannelUploads.shared.uploads(of: expandedYouTubeChannels.keys))
    }

    func buildYouTubeChannelItems() {
        displayItems = youtubeRows.channels(YouTubeManager.shared.channels).map { LibraryBrowserItem($0) }
    }

    /// Search tab (YouTube source): run the typed query as a YouTube channel search, or show
    /// the results of an unchanged one; `force` (Refresh) re-runs it.
    func loadYouTubeSearchResults(force: Bool = false) {
        errorMessage = nil
        let started = youtubeSearch.submit(searchQuery, force: force) { [weak self] error in
            guard let self, self.isYouTubeChannelSearch else { return }
            self.isLoading = false
            if let error {
                self.errorMessage = error.localizedDescription
            } else {
                self.rebuildCurrentModeItems()
            }
        }
        guard started else {
            isLoading = false
            buildYouTubeSearchItems()
            return
        }
        displayItems = []
        rowsReplaced()
        isLoading = true
    }

    func buildYouTubeSearchItems() {
        displayItems = youtubeRows.channelSearch(youtubeSearch.results).map { LibraryBrowserItem($0) }
    }

    /// Fetch a channel's uploads again, expanding it.
    func refreshYouTubeChannel(_ channel: YouTubeChannel) {
        expandedYouTubeChannels[channel.id] = channel
        YouTubeChannelUploads.shared.load([channel], force: true)
    }

    func removeYouTubeChannel(_ channel: YouTubeChannel) {
        YouTubeManager.shared.removeChannel(channel)
        expandedYouTubeChannels.removeValue(forKey: channel.id)
        rebuildCurrentModeItems()
    }
}
