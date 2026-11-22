//
//  AgentsOnboardingView.swift
//  boringNotch
//
//  First-run step that tells the user which coding agents were connected, and that nothing is needed from them.
//

import AgentHub
import SwiftUI

struct AgentsOnboardingView: View {
    let onContinue: () -> Void

    @ObservedObject private var runtime = AgentRuntime.shared
    @State private var tools: [AgentRuntime.AgentTool] = []

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundColor(.effectiveAccent)
                .padding(.top, 32)

            Text("Your coding agents are connected")
                .font(.title)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Cove found these tools on this Mac and added hooks so they can report here. Their configs were backed up first, and you can switch any of them off in Settings.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if tools.isEmpty {
                        Text("No supported tools found yet. They connect automatically once installed.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tools) { tool in
                        Toggle(isOn: Binding(
                            get: { tool.installed },
                            set: { on in Task { await runtime.setTool(tool.id, enabled: on); tools = runtime.tools().filter(\.detected) } }
                        )) {
                            Text(tool.name)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 24)

            Button(action: onContinue) {
                Text("Continue")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .onAppear { tools = runtime.tools().filter(\.detected) }
        .onChange(of: runtime.toolsVersion) { _, _ in tools = runtime.tools().filter(\.detected) }
    }
}
