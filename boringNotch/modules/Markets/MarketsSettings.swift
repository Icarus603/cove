//
//  MarketsSettings.swift
//  boringNotch
//
//  Settings → Markets: the watchlist, colour convention, and the optional read-only Binance key.
//

import SwiftUI

struct MarketsSettings: View {
    @ObservedObject private var store = MarketsStore.shared
    @AppStorage("markets.redUp") private var redUp = MarketsFormat.defaultRedUp
    @AppStorage("markets.hideBalance") private var hideBalance = false

    @State private var newSymbol = ""
    @State private var adding = false
    @State private var addError: String?

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var hasKeys = BinanceClient.hasKeys
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section {
                ForEach(store.watchlist, id: \.self) { symbol in
                    HStack {
                        Text(symbol).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) { store.remove(symbol) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove \(symbol)"))
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                HStack {
                    TextField("Symbol, e.g. BTC or ETHUSDT", text: $newSymbol)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(adding || newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Watchlist")
            } footer: {
                Text("Prices come from Binance's public market data and need no account. A bare name like BTC means BTCUSDT.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Red for up, green for down", isOn: $redUp)
            } header: {
                Text("Display")
            }

            Section {
                if hasKeys {
                    LabeledContent("API key") { Text("Saved in Keychain").foregroundStyle(.secondary) }
                    Toggle("Hide balance", isOn: $hideBalance)
                    HStack {
                        Button("Test connection", action: test).disabled(testing)
                        Button("Remove keys", role: .destructive, action: removeKeys)
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(testOK ? Color.green : Color.orange)
                    }
                } else {
                    TextField("API key", text: $apiKey)
                    SecureField("API secret", text: $apiSecret)
                    Button("Save keys", action: saveKeys)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || apiSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Binance account (optional)")
            } footer: {
                Text("Shows your estimated spot balance in the Markets tab. Create a key with read-only permission, no trading and no withdrawals, and restrict it to your IP address. Cove only reads balances: it never places or cancels orders and never moves funds. The key is stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Markets")
    }

    private func add() {
        let raw = newSymbol
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty, !adding else { return }
        adding = true; addError = nil
        Task {
            if await store.add(raw) != nil {
                newSymbol = ""
            } else {
                addError = String(localized: "Binance has no pair named \(BinanceClient.normalize(raw)).")
            }
            adding = false
        }
    }

    private func saveKeys() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainStore.write(key, account: BinanceClient.apiKeyAccount),
              KeychainStore.write(secret, account: BinanceClient.apiSecretAccount) else {
            testResult = String(localized: "Could not save to the Keychain."); testOK = false
            return
        }
        apiKey = ""; apiSecret = ""; hasKeys = true; testResult = nil
        store.credentialsChanged()
        test()
    }

    private func removeKeys() {
        KeychainStore.delete(BinanceClient.apiKeyAccount)
        KeychainStore.delete(BinanceClient.apiSecretAccount)
        hasKeys = false; testResult = nil
        store.credentialsChanged()
    }

    private func test() {
        testing = true; testResult = nil
        Task {
            if let error = await store.testConnection() {
                testResult = error; testOK = false
            } else {
                testResult = String(localized: "Connected."); testOK = true
            }
            testing = false
        }
    }
}
