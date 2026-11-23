//
//  MarketsSettings.swift
//  boringNotch
//
//  Settings → Markets: the watchlist (search, add, reorder, remove), colours, and the optional read-only Binance key
//  with the balance it unlocks.
//

import SwiftUI

struct MarketsSettings: View {
    @ObservedObject private var store = MarketsStore.shared
    @ObservedObject private var directory = SymbolDirectory.shared
    @AppStorage("markets.redUp") private var redUp = MarketsFormat.defaultRedUp
    @AppStorage("markets.hideBalance") private var hideBalance = false

    #if DEBUG
    @State private var query = ProcessInfo.processInfo.environment["COVE_SHOT_MARKETS_QUERY"] ?? ""   // scripts/shots.sh
    #else
    @State private var query = ""
    #endif
    @State private var addError: String?
    @State private var isAdding = false

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var hasKeys = BinanceClient.hasKeys
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testOK = false

    private var suggestions: [String] { directory.suggestions(for: query, excluding: store.watchlist) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            watchlistSection
            addSection
            displaySection
            accountSection
        }
        .formStyle(.grouped)
        .navigationTitle("Markets")
        .task { await directory.loadIfNeeded() }
        .task { if hasKeys, store.portfolio == nil { await runTest() } }
    }

    // MARK: Watchlist

    private var watchlistSection: some View {
        Section {
            if store.watchlist.isEmpty {
                Text("Nothing is watched yet. Search for a pair below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.watchlist.enumerated()), id: \.element) { index, symbol in
                HStack(spacing: 10) {
                    pairLabel(symbol)
                    Spacer()
                    if let price = store.tickers[symbol]?.price ?? directory.prices[symbol] {
                        Text(MarketsFormat.price(price))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    iconButton("chevron.up", help: "Move up", disabled: index == 0) { store.move(symbol, by: -1) }
                    iconButton("chevron.down", help: "Move down", disabled: index == store.watchlist.count - 1) { store.move(symbol, by: 1) }
                    iconButton("minus.circle", help: "Remove \(symbol)", disabled: false, destructive: true) { store.remove(symbol) }
                }
            }
        } header: {
            HStack {
                Text("Watchlist")
                Spacer()
                Button("Reset to default") { store.resetWatchlist() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(store.watchlist == MarketsStore.defaultWatchlist)
            }
        }
    }

    // MARK: Add

    private var addSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Pair", text: $query, prompt: Text("Search pairs, e.g. BTC, ETH, SOL"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(submit)
                if isAdding { ProgressView().controlSize(.small) }
            }

            if let addError {
                Text(addError).font(.caption).foregroundStyle(.orange)
            }

            if trimmedQuery.isEmpty {
                popularRow
            } else if directory.isLoading && directory.prices.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading Binance's pairs…").foregroundStyle(.secondary) }
            } else if directory.failed {
                HStack {
                    Text("Could not load Binance's pair list.").foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { Task { await directory.reload() } }
                }
            } else if suggestions.isEmpty {
                Text("No pair matches “\(trimmedQuery)”.").foregroundStyle(.secondary)
            } else {
                ForEach(suggestions, id: \.self) { symbol in
                    HStack(spacing: 10) {
                        pairLabel(symbol)
                        Spacer()
                        if let price = directory.prices[symbol] {
                            Text(MarketsFormat.price(price)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Button { add(symbol) } label: { Label("Add", systemImage: "plus.circle.fill").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.effectiveAccent)
                            .help(Text("Add"))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { add(symbol) }
                }
            }
        } header: {
            Text("Add a pair")
        } footer: {
            Text("Prices come from Binance's public market data and need no account. Press Return to add the top match.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var popularRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Popular").font(.caption).foregroundStyle(.secondary)
            let popular = directory.popular(excluding: store.watchlist)
            if popular.isEmpty {
                Text(directory.isLoading ? "…" : "—").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(popular, id: \.self) { symbol in
                        Button { add(symbol) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                Text(BinanceClient.split(symbol).base).font(.system(.callout, weight: .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle(isOn: $redUp) {
                HStack(spacing: 10) {
                    Text("Red for up, green for down")
                    Spacer()
                    HStack(spacing: 8) {
                        Label("2.34%", systemImage: "arrowtriangle.up.fill").foregroundStyle(MarketsPalette.up(redUp: redUp))
                        Label("1.20%", systemImage: "arrowtriangle.down.fill").foregroundStyle(MarketsPalette.down(redUp: redUp))
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        } header: {
            Text("Display")
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if hasKeys {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(statusText).foregroundStyle(statusColor)
                    }
                }
                if let portfolio = store.portfolio {
                    LabeledContent("Estimated balance") {
                        Text(hideBalance ? "••••••" : "≈ \(MarketsFormat.money(portfolio.total)) USDT")
                            .font(.system(.body, design: .monospaced)).privacySensitive()
                    }
                    ForEach(portfolio.holdings.prefix(8)) { holding in
                        HStack {
                            Text(holding.asset).font(.system(.callout, weight: .semibold))
                            Spacer()
                            Text(hideBalance ? "••••" : holding.amount.formatted(.number.precision(.fractionLength(0...6))))
                                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).privacySensitive()
                            Text(hideBalance ? "" : holding.value.map { "≈ " + MarketsFormat.money($0) } ?? "—")
                                .font(.system(.callout, design: .monospaced)).frame(minWidth: 90, alignment: .trailing).privacySensitive()
                        }
                    }
                }
                Toggle("Hide balance", isOn: $hideBalance)
                HStack {
                    Button("Refresh") { Task { await runTest() } }.disabled(isTesting)
                    Button("Remove keys", role: .destructive, action: removeKeys)
                }
            } else {
                LabeledContent("API key") {
                    TextField("API key", text: $apiKey, prompt: Text("Paste your API key"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 300)
                }
                LabeledContent("API secret") {
                    SecureField("API secret", text: $apiSecret, prompt: Text("Paste your API secret"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 300)
                }
                HStack {
                    Button("Save and test", action: saveKeys)
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || apiSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Open Binance API management", destination: URL(string: "https://www.binance.com/en/my/settings/api-management")!)
                        .font(.callout)
                    if let testMessage, !testOK { Text(testMessage).font(.caption).foregroundStyle(.orange) }
                }
            }
        } header: {
            Text("Binance account (optional)")
        } footer: {
            Text("Shows your estimated spot balance in the Markets tab. Create a key with read-only permission, no trading and no withdrawals, and restrict it to your IP address. Cove only reads balances: it never places or cancels orders and never moves funds. The key is stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: LocalizedStringKey {
        if isTesting { return "Checking…" }
        if let message = testMessage, !testOK { return LocalizedStringKey(message) }
        return store.portfolio == nil ? "Not checked yet" : "Connected."
    }

    private var statusColor: Color { isTesting ? .secondary : (testOK || store.portfolio != nil ? .green : .orange) }

    // MARK: Pieces

    private func pairLabel(_ symbol: String) -> some View {
        let parts = BinanceClient.split(symbol)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.base).font(.system(.body, weight: .semibold))
            if !parts.quote.isEmpty { Text("/" + parts.quote).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, disabled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
            .buttonStyle(.borderless)
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .disabled(disabled)
            .help(Text(help))
    }

    // MARK: Actions

    private func add(_ symbol: String) {
        store.addKnown(symbol)
        query = ""; addError = nil
    }

    /// Return in the search box: the top match, or, when the list has nothing, ask Binance directly.
    private func submit() {
        guard !trimmedQuery.isEmpty, !isAdding else { return }
        if let first = suggestions.first { add(first); return }
        let raw = trimmedQuery
        isAdding = true; addError = nil
        Task {
            if await store.add(raw) != nil { query = "" } else { addError = String(localized: "Binance has no pair named \(BinanceClient.normalize(raw)).") }
            isAdding = false
        }
    }

    private func saveKeys() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainStore.write(key, account: BinanceClient.apiKeyAccount),
              KeychainStore.write(secret, account: BinanceClient.apiSecretAccount) else {
            testMessage = String(localized: "Could not save to the Keychain."); testOK = false
            return
        }
        apiKey = ""; apiSecret = ""; hasKeys = true; testMessage = nil
        store.credentialsChanged()
        Task { await runTest() }
    }

    private func removeKeys() {
        KeychainStore.delete(BinanceClient.apiKeyAccount)
        KeychainStore.delete(BinanceClient.apiSecretAccount)
        hasKeys = false; testMessage = nil; testOK = false
        store.credentialsChanged()
    }

    private func runTest() async {
        isTesting = true; testMessage = nil
        if let error = await store.testConnection() { testMessage = error; testOK = false } else { testOK = true }
        isTesting = false
    }
}
