import AppKit
import Markdown
import SwiftUI

// SEARCH-HELPER: AgentPreviewPanelView, preview segment, semi-rendered markdown, secure html preview

/// How Markdown is presented.
///
/// Not part of `AgentUtilityPanelTabState`: the HTML Rendered/Source choice is per tab because it
/// changes what a document *is*, while this is a reading preference that should not fork between
/// two tabs showing the same file. Phase 1 keeps it as view state defaulting to semi-rendered,
/// which decision row 3 makes the defining Preview behaviour.
enum AgentPreviewMarkdownDisplayMode: String, CaseIterable, Identifiable {
    /// Xcode-style: the source stays visible and styling is layered on top of it.
    case semiRendered
    /// The existing fully-rendered transcript renderer.
    case rendered

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .semiRendered: "Semi"
        case .rendered: "Rendered"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .semiRendered: "Show Markdown with its source markers"
        case .rendered: "Show fully rendered Markdown"
        }
    }
}

/// The Preview segment of the right utility panel.
///
/// Renders whatever `PreviewDocumentReference` the active tab holds, and nothing else decides what
/// that is: the Changes segment's artifact banner and the picker below both work by writing that
/// reference through the view model, so this surface has exactly one input.
struct AgentPreviewPanelView: View {
    @ObservedObject var utilityPanelUI: AgentUtilityPanelUIStore
    let agentModeVM: AgentModeViewModel

    @StateObject private var viewModel = AgentDocumentPreviewViewModel()
    /// Documents this session's agent wrote, offered at the top of the picker.
    ///
    /// A private index rather than a shared one: it is fed only while the picker is on screen, so
    /// browsing costs one decode pass and reading a document costs none.
    @StateObject private var artifactIndex = AgentSessionArtifactIndex()

    @State private var context = AgentPreviewResolutionContext()
    @State private var candidateFiles: [AgentPreviewCandidateFile] = []
    @State private var rootRelativePathsByRoot: [UUID: [String]] = [:]
    @State private var rootRelativePathSignatures: [UUID: Int] = [:]
    @State private var markdownDisplayMode: AgentPreviewMarkdownDisplayMode = .semiRendered
    @State private var markdownOutline: [MarkdownOutlineHeading] = []
    @State private var headingNavigationRequest: AgentMarkdownHeadingNavigationRequest?
    @State private var headingNavigationSequence = 0
    @State private var isOutlinePresented = false
    @State private var pendingExternalURL: URL?
    @State private var pendingScriptEnableDocument: PreviewDocumentReference?
    @State private var htmlPreviewMessage: String?

    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let headerSpacing: CGFloat = 6
        static let headerBottomPadding: CGFloat = 6
        static let readingHorizontalPadding: CGFloat = 14
        static let readingVerticalPadding: CGFloat = 12
        static let titleSizeAtNormal: CGFloat = 11
        static let badgeSizeAtNormal: CGFloat = 8
        static let messageSizeAtNormal: CGFloat = 10
        static let backGlyphSizeAtNormal: CGFloat = 9
        static let openGlyphSizeAtNormal: CGFloat = 10
        static let sourceFontSizeAtNormal: CGFloat = 13
        static let statusDotSize: CGFloat = 5
        static let toggleTransitionDuration: Double = 0.12
    }

    private var preset: FontScalePreset {
        fontScale.preset
    }

    private var reference: PreviewDocumentReference? {
        utilityPanelUI.snapshot.panel.previewDocument
    }

    private var htmlDisplayMode: AgentPreviewHTMLDisplayMode {
        utilityPanelUI.snapshot.panel.htmlDisplayMode
    }

    private var htmlScriptsEnabled: Bool {
        guard let reference else { return false }
        return utilityPanelUI.snapshot.panel.areHTMLScriptsEnabled(for: reference)
    }

    var body: some View {
        Group {
            if reference == nil {
                picker
            } else {
                document
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: contextRefreshKey) {
            await refreshContext()
        }
        .task(id: outlineRefreshKey) {
            await refreshOutline()
        }
        .onChange(of: reference) { _, next in
            pendingScriptEnableDocument = nil
            viewModel.show(next, context: context)
        }
        .onDisappear {
            viewModel.stop()
        }
        .confirmationDialog(
            "Open this link in your browser?",
            isPresented: externalLinkPrompt,
            titleVisibility: .visible,
            presenting: pendingExternalURL
        ) { url in
            Button("Open in Browser") {
                pendingExternalURL = nil
                NSWorkspace.shared.open(url)
            }
            Button("Copy Link") {
                pendingExternalURL = nil
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Cancel", role: .cancel) { pendingExternalURL = nil }
        } message: { url in
            // Decision row 4: every affordance that leaves the preview says what leaving costs.
            Text(
                """
                \(url.absoluteString)

                This page was written by an agent and has not been reviewed. \
                \(externalNavigationSecurityMessage)
                """
            )
        }
        .confirmationDialog(
            "Run scripts in this document?",
            isPresented: scriptEnablePrompt,
            titleVisibility: .visible,
            presenting: pendingScriptEnableDocument
        ) { document in
            Button("Enable once") {
                pendingScriptEnableDocument = nil
                agentModeVM.enableUtilityPanelHTMLScriptsOnce(for: document)
            }
            Button("Cancel", role: .cancel) {
                pendingScriptEnableDocument = nil
            }
        } message: { document in
            Text(
                """
                \(document.fileName) was written by an agent and is untrusted. Scripts can read the \
                document and non-hidden files in its folder and subfolders. Network access, forms, \
                frames, workers, and popups stay blocked.

                This permission applies only to this exact document and is cleared when you navigate away.
                """
            )
        }
    }

    // MARK: - Document

    private var document: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = viewModel.linkFeedback {
                linkFeedbackBar(message)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Layout.headerSpacing) {
                Button {
                    agentModeVM.selectUtilityPanelPreviewDocument(nil)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: preset.scaledMetric(Layout.backGlyphSizeAtNormal), weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Choose another document")
                .accessibilityLabel("Choose another document")

                Text(titleText)
                    .font(preset.swiftUIFont(sizeAtNormal: Layout.titleSizeAtNormal, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .hoverTooltip(subtitleText)

                kindBadge

                Spacer(minLength: 4)

                outlineControl

                liveReloadIndicator

                Button {
                    openInEditor()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: preset.scaledMetric(Layout.openGlyphSizeAtNormal), weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.state.document == nil)
                .hoverTooltip("Open in Editor")
                .accessibilityLabel("Open in editor")
            }

            displayModeToggle
        }
        .padding(.horizontal, Layout.readingHorizontalPadding)
        .padding(.bottom, Layout.headerBottomPadding)
        .accessibilityElement(children: .contain)
    }

    private var titleText: String {
        viewModel.state.document?.fileName ?? reference?.fileName ?? "Document"
    }

    private var subtitleText: String {
        viewModel.state.document?.displayPath ?? reference?.relativePath ?? ""
    }

    @ViewBuilder
    private var kindBadge: some View {
        if let kind = viewModel.state.document?.kind {
            Text(kind.badgeLabel)
                .font(preset.swiftUIFont(sizeAtNormal: Layout.badgeSizeAtNormal, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .accessibilityLabel(kind.accessibilityLabel)
        }
    }

    @ViewBuilder
    private var outlineControl: some View {
        if viewModel.state.document?.kind == .markdown, !markdownOutline.isEmpty {
            Button {
                isOutlinePresented.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: preset.scaledMetric(Layout.openGlyphSizeAtNormal), weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip("Document Outline")
            .accessibilityLabel("Document outline")
            .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
                AgentMarkdownOutlinePopover(headings: markdownOutline) { heading in
                    headingNavigationSequence += 1
                    headingNavigationRequest = AgentMarkdownHeadingNavigationRequest(
                        id: headingNavigationSequence,
                        headingID: heading.id,
                        animated: !reduceMotion
                    )
                    isOutlinePresented = false
                }
            }
        }
    }

    /// A quiet dot rather than a banner: live reload is the expected state, so it should read as
    /// reassurance at a glance and only earn attention when it degrades.
    @ViewBuilder
    private var liveReloadIndicator: some View {
        if viewModel.state.document != nil {
            Circle()
                .fill(viewModel.isWatchDegraded ? Color.orange.opacity(0.7) : Color.green.opacity(0.6))
                .frame(width: Layout.statusDotSize, height: Layout.statusDotSize)
                .hoverTooltip(
                    viewModel.isWatchDegraded
                        ? "This document could not be watched, so the preview re-checks it every couple of seconds."
                        : "Reloads automatically when this file changes on disk."
                )
                .accessibilityLabel(
                    viewModel.isWatchDegraded ? "Live reload degraded to polling" : "Live reload active"
                )
        }
    }

    @ViewBuilder
    private var displayModeToggle: some View {
        switch viewModel.state.document?.kind {
        case .markdown:
            Picker("Markdown presentation", selection: $markdownDisplayMode) {
                ForEach(AgentPreviewMarkdownDisplayMode.allCases) { mode in
                    Text(mode.title)
                        .accessibilityLabel(mode.accessibilityLabel)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .accessibilityLabel("Markdown presentation")
            .accessibilityValue(markdownDisplayMode.title)
        case .html:
            HStack(spacing: Layout.headerSpacing) {
                Picker("HTML presentation", selection: htmlModeBinding) {
                    ForEach(AgentPreviewHTMLDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel("HTML presentation")
                .accessibilityValue(htmlDisplayMode.title)

                Spacer(minLength: 4)

                htmlScriptControl
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var htmlScriptControl: some View {
        if htmlScriptsEnabled {
            Button {
                agentModeVM.disableUtilityPanelHTMLScripts()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: Layout.statusDotSize, height: Layout.statusDotSize)
                    Text("Scripts on · folder-scoped")
                        .font(preset.swiftUIFont(sizeAtNormal: Layout.badgeSizeAtNormal, weight: .semibold))
                    Image(systemName: "xmark")
                        .font(.system(size: preset.scaledMetric(7), weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .hoverTooltip("Turn scripts off")
            .accessibilityLabel("Scripts on, folder-scoped. Turn scripts off")
        } else {
            Button("Run scripts") {
                pendingScriptEnableDocument = reference
            }
            .buttonStyle(.plain)
            .font(preset.swiftUIFont(sizeAtNormal: Layout.messageSizeAtNormal, weight: .medium))
            .foregroundStyle(.secondary)
            .hoverTooltip("Run this document's scripts once")
            .accessibilityLabel("Run scripts in this document")
        }
    }

    private var htmlModeBinding: Binding<AgentPreviewHTMLDisplayMode> {
        Binding(
            get: { htmlDisplayMode },
            set: { agentModeVM.setUtilityPanelHTMLDisplayMode($0) }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .empty:
            AgentPreviewMessageView(
                symbolName: "doc.text",
                title: "No Document Selected",
                message: "Pick a Markdown or HTML file to read it alongside the conversation."
            )
        case .loading:
            AgentPreviewMessageView(
                symbolName: "doc.text",
                title: "Opening…",
                message: "Reading \(titleText)."
            )
        case let .ready(content):
            readyContent(content)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: Layout.toggleTransitionDuration),
                    value: markdownDisplayMode
                )
        case let .tooLarge(document, byteCount):
            AgentPreviewMessageView(
                symbolName: "doc.badge.ellipsis",
                title: "Too Large to Preview",
                message: """
                \(document.fileName) is \(Self.byteLabel(byteCount)). Documents this size are opened \
                in an editor instead, because the preview lays text out while the window resizes.
                """,
                actionTitle: "Open in Editor",
                action: openInEditor
            )
        case let .missing(document):
            AgentPreviewMessageView(
                symbolName: "questionmark.folder",
                title: "Document Not Found",
                message: "Nothing exists at \(document.displayPath) right now. It will appear here if it is written again."
            )
        case let .unresolvable(reference, failure):
            AgentPreviewMessageView(
                symbolName: failure.symbolName,
                title: failure.title,
                message: failure.message(for: reference)
            )
        case let .failed(document, message):
            AgentPreviewMessageView(
                symbolName: "exclamationmark.triangle",
                title: "Could Not Read Document",
                message: "\(document.fileName): \(message)",
                actionTitle: "Try Again",
                action: viewModel.reloadNow
            )
        }
    }

    @ViewBuilder
    private func readyContent(_ content: AgentPreviewDocumentContent) -> some View {
        switch content.document.kind {
        case .markdown:
            markdownContent(content)
        case .html:
            htmlContent(content)
        }
    }

    // MARK: - Markdown

    /// The signature surface.
    ///
    /// `.id(content.document.reference)` — the *reference*, not the revision — is what preserves
    /// scroll position across live reloads (decision row 15): a reload keeps the same identity, so
    /// AppKit keeps the text view and the scroll offset survives, while opening a different
    /// document remounts and correctly starts at the top.
    private func markdownContent(_ content: AgentPreviewDocumentContent) -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                Group {
                    switch markdownDisplayMode {
                    case .semiRendered:
                        AgentSemiRenderedMarkdownView(
                            text: content.text,
                            headings: markdownOutline,
                            navigationRequest: headingNavigationRequest,
                            linkOpener: linkOpener
                        )
                    case .rendered:
                        AgentRenderedMarkdownView(
                            text: content.text,
                            document: content.document,
                            rootRelativePaths: rootRelativePathsByRoot[content.document.reference.rootID] ?? [],
                            rootPathSignature: rootRelativePathSignatures[content.document.reference.rootID] ?? 0,
                            maximumImageDisplayWidth: max(
                                1,
                                geometry.size.width - (Layout.readingHorizontalPadding * 2)
                            ),
                            navigationRequest: headingNavigationRequest,
                            linkOpener: linkOpener
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.readingHorizontalPadding)
                .padding(.vertical, Layout.readingVerticalPadding)
            }
        }
        .id(content.document.reference)
    }

    // MARK: - HTML

    @ViewBuilder
    private func htmlContent(_ content: AgentPreviewDocumentContent) -> some View {
        switch htmlDisplayMode {
        case .rendered:
            VStack(spacing: 0) {
                if let htmlPreviewMessage {
                    AgentPreviewInlineNoticeView(message: htmlPreviewMessage)
                }
                SecureHTMLPreviewView(
                    documentRootURL: content.document.checkoutRootURL,
                    relativePath: content.document.reference.relativePath,
                    mode: htmlScriptsEnabled ? .scriptsEnabled : .scriptsBlocked,
                    onExternalLinkRequested: { pendingExternalURL = $0 },
                    onInScopeDocumentRequested: reopenInScopeDocumentWithoutScripts,
                    onStateChange: { state in
                        htmlPreviewMessage = if case let .failed(message) = state { message } else { nil }
                    }
                )
                // Remounting on the content revision is how an HTML document live-reloads: the
                // secure surface deliberately ignores a repeat load of the same path so that
                // ordinary SwiftUI updates cannot reload the page underneath the reader. The
                // revision only moves when the bytes actually changed, so this costs one reload per
                // real edit. The mode bit is also part of identity so opting in or
                // disabling always creates a new coordinator, configuration, handler, and
                // non-persistent store rather than mutating an existing security stack.
                .id(AgentHTMLPreviewMountKey(
                    revision: content.revision,
                    scriptsEnabled: htmlScriptsEnabled
                ))
            }
        case .source:
            ScrollView(.vertical) {
                // Highlighting degrades to plain monospace on its own for HTML past the
                // highlighter's density ceiling, which is the documented fallback for this flag.
                AttributedTextView(
                    attributedString: CodeHighlightCache.shared.highlighted(
                        content.text,
                        language: "html",
                        fontPointSize: preset.scaledMetric(Layout.sourceFontSizeAtNormal)
                    ),
                    isEditable: false,
                    allowsTextSelection: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.readingHorizontalPadding)
                .padding(.vertical, Layout.readingVerticalPadding)
            }
            .id(content.document.reference)
        }
    }

    // MARK: - Picker

    private var picker: some View {
        AgentPreviewDocumentPickerView(
            entries: pickerEntries,
            onSelect: { entry in
                agentModeVM.selectUtilityPanelPreviewDocument(entry.reference)
            }
        )
        .task(id: contextRefreshKey) {
            ingestSessionArtifacts()
        }
    }

    private var pickerEntries: [AgentPreviewPickerEntry] {
        AgentPreviewDocumentPicker.entries(
            artifacts: artifactIndex.artifacts,
            files: candidateFiles,
            context: context
        )
    }

    // MARK: - Link activation

    private var linkOpener: MarkdownFileLinkOpener {
        MarkdownFileLinkOpener { target in
            await follow(target)
        }
    }

    /// Follows a link from inside the document.
    ///
    /// Root-scoped navigation comes first so `[[design]]` and `[../notes/plan.md](…)` move the
    /// preview instead of launching another application, and only links the document's own root
    /// cannot answer fall through to the app's ordinary file-opening path.
    @MainActor
    private func follow(_ target: MarkdownFileLinkTarget) async -> Bool {
        guard let document = viewModel.state.document else { return false }

        let candidates = rootRelativePathsByRoot[document.reference.rootID] ?? []
        let resolver = WikiLinkResolver(rootRelativePaths: candidates)

        // The raw destination first because a wiki link carries its target verbatim; the decoded
        // path second so a percent-encoded Markdown link still resolves.
        for rawTarget in [target.rawDestination, target.normalizedPath] {
            if target.isObsidianEmbed {
                switch resolver.resolveEmbed(rawTarget: rawTarget) {
                case .resolved(_, _, .image):
                    viewModel.reportLinkFeedback("Image embeds appear inline in Rendered mode.")
                    return true
                case let .resolved(relativePath, _, .note):
                    if navigateToPreviewDocument(relativePath, rootID: document.reference.rootID) {
                        return true
                    }
                case .rejected:
                    break
                }
            } else if case let .resolved(relativePath, _) = resolver.resolve(rawTarget: rawTarget),
                      navigateToPreviewDocument(relativePath, rootID: document.reference.rootID)
            {
                return true
            }
        }

        if let fileManager = agentModeVM.promptManager?.fileManager,
           await fileManager.openFileForMarkdownLink(target)
        {
            return true
        }

        // Quiet and inline, never a modal: a stale link in a document being edited is normal.
        viewModel.reportLinkFeedback("No document named “\(target.normalizedPath)” in \(document.rootName).")
        return true
    }

    private func navigateToPreviewDocument(_ relativePath: String, rootID: UUID) -> Bool {
        let fileExtension = (relativePath as NSString).pathExtension
        guard AgentSessionArtifactKind(fileExtension: fileExtension) != nil else { return false }
        agentModeVM.selectUtilityPanelPreviewDocument(
            PreviewDocumentReference(rootID: rootID, relativePath: relativePath)
        )
        return true
    }

    private func linkFeedbackBar(_ message: String) -> some View {
        AgentPreviewInlineNoticeView(message: message)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: message)
    }

    // MARK: - Actions

    private func openInEditor() {
        guard let document = viewModel.state.document else { return }
        let fileURL = document.fileURL
        Task { @MainActor in
            if let fileManager = agentModeVM.promptManager?.fileManager,
               let target = MarkdownFileLinkTarget.parse(rawDestination: fileURL.path),
               await fileManager.openFileForMarkdownLink(target)
            {
                return
            }
            _ = NSWorkspace.shared.open(fileURL)
        }
    }

    private var externalNavigationSecurityMessage: String {
        if htmlScriptsEnabled {
            return """
            Network loads remain blocked and scripts run only against this folder-scoped preview; \
            your browser will apply none of these restrictions.
            """
        }
        return "The preview blocks scripts and network loads; your browser will not."
    }

    private var scriptEnablePrompt: Binding<Bool> {
        Binding(
            get: { pendingScriptEnableDocument != nil },
            set: { isPresented in
                if !isPresented { pendingScriptEnableDocument = nil }
            }
        )
    }

    private func reopenInScopeDocumentWithoutScripts(_ url: URL) {
        guard let document = viewModel.state.document else {
            agentModeVM.disableUtilityPanelHTMLScripts()
            return
        }

        let relativePath = url.path.drop(while: { $0 == "/" })
        guard !relativePath.isEmpty else {
            agentModeVM.disableUtilityPanelHTMLScripts()
            return
        }

        // The policy has already proved scheme and host. Writing a different exact
        // reference through the state authority clears consent before the target load.
        agentModeVM.selectUtilityPanelPreviewDocument(
            PreviewDocumentReference(
                rootID: document.reference.rootID,
                relativePath: String(relativePath)
            )
        )
    }

    private var externalLinkPrompt: Binding<Bool> {
        Binding(
            get: { pendingExternalURL != nil },
            set: { isPresented in
                if !isPresented { pendingExternalURL = nil }
            }
        )
    }

    // MARK: - Context

    private var outlineRefreshKey: AgentPreviewOutlineRefreshKey {
        guard let content = viewModel.state.content, content.document.kind == .markdown else {
            return AgentPreviewOutlineRefreshKey(reference: nil, revision: nil)
        }
        return AgentPreviewOutlineRefreshKey(
            reference: content.document.reference,
            revision: content.revision
        )
    }

    private func refreshOutline() async {
        guard let content = viewModel.state.content, content.document.kind == .markdown else {
            markdownOutline = []
            isOutlinePresented = false
            return
        }
        let reference = content.document.reference
        let revision = content.revision
        let source = content.text
        let headings = await Task.detached(priority: .userInitiated) {
            MarkdownOutlineExtractor.headings(in: source)
        }.value
        guard !Task.isCancelled,
              viewModel.state.content?.document.reference == reference,
              viewModel.state.content?.revision == revision
        else { return }
        markdownOutline = headings
        if headings.isEmpty { isOutlinePresented = false }
    }

    /// Changes to this restate the workspace facts the reference resolves against.
    private var contextRefreshKey: AgentPreviewContextRefreshKey {
        AgentPreviewContextRefreshKey(
            tabID: utilityPanelUI.snapshot.currentTabID,
            reference: reference
        )
    }

    private func refreshContext() async {
        let bindings = utilityPanelUI.snapshot.currentTabID
            .flatMap { agentModeVM.sessions[$0] }?
            .worktreeBindings ?? []

        var roots: [AgentPreviewDocumentRoot] = []
        var files: [AgentPreviewCandidateFile] = []
        var rootRelativePaths: [UUID: [String]] = [:]
        if let store = agentModeVM.promptManager?.workspaceFileContextStore {
            for rootRef in await store.rootRefs(scope: .visibleWorkspace) {
                roots.append(AgentPreviewDocumentRoot(
                    id: rootRef.id,
                    name: rootRef.name,
                    path: rootRef.standardizedFullPath
                ))
                for record in await store.files(inRoot: rootRef.id) {
                    rootRelativePaths[rootRef.id, default: []].append(record.standardizedRelativePath)
                    let fileExtension = (record.standardizedRelativePath as NSString).pathExtension
                    guard AgentSessionArtifactKind(fileExtension: fileExtension) != nil else { continue }
                    files.append(AgentPreviewCandidateFile(
                        rootID: rootRef.id,
                        relativePath: record.standardizedRelativePath,
                        modifiedAt: record.modificationDate
                    ))
                }
            }
        }

        guard !Task.isCancelled else { return }
        context = AgentPreviewResolutionContext(roots: roots, worktreeBindings: bindings)
        candidateFiles = files
        rootRelativePathsByRoot = rootRelativePaths
        rootRelativePathSignatures = rootRelativePaths.mapValues(\.hashValue)
        viewModel.show(reference, context: context)
    }

    private func ingestSessionArtifacts() {
        guard let tabID = utilityPanelUI.snapshot.currentTabID,
              let session = agentModeVM.sessions[tabID]
        else {
            artifactIndex.reset()
            return
        }
        artifactIndex.ingest(session.items)
    }

    private static func byteLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// The identity that decides when the workspace facts behind the preview are re-read.
private struct AgentHTMLPreviewMountKey: Hashable {
    let revision: Int
    let scriptsEnabled: Bool
}

private struct AgentPreviewContextRefreshKey: Equatable {
    let tabID: UUID?
    let reference: PreviewDocumentReference?
}

private struct AgentPreviewOutlineRefreshKey: Equatable {
    let reference: PreviewDocumentReference?
    let revision: Int?
}

private struct AgentMarkdownHeadingNavigationRequest: Equatable {
    let id: Int
    let headingID: Int
    let animated: Bool
}

// MARK: - Semi-rendered surface

/// Compiles and displays semi-rendered Markdown.
///
/// Compilation is off the main actor and keyed on text plus font size, mirroring
/// `EnhancedMarkdownView`, because the compiler walks the whole document and a synchronous compile
/// during layout would stutter the transcript beside the panel. Until the first compile lands the
/// verbatim source is shown in the body font — which is legitimate output here rather than a
/// placeholder, since the compiler's contract is that its result *is* the source.
private struct AgentSemiRenderedMarkdownView: View {
    let text: String
    let headings: [MarkdownOutlineHeading]
    let navigationRequest: AgentMarkdownHeadingNavigationRequest?
    let linkOpener: MarkdownFileLinkOpener?

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var compiled: NSAttributedString?

    private var fontSize: CGFloat {
        CGFloat(fontScale.preset.rawValue)
    }

    var body: some View {
        AttributedTextView(
            attributedString: compiled ?? plainFallback,
            isEditable: false,
            allowsTextSelection: true,
            linkOpener: linkOpener,
            scrollRequest: textScrollRequest
        )
        // `.task(id:)` owns cancellation: a new document, a reload, or a font-size change
        // supersedes the in-flight compile without a hand-rolled task handle.
        .task(id: CompileKey(text: text, fontSize: fontSize)) {
            await compile()
        }
    }

    private var textScrollRequest: MarkdownTextScrollRequest? {
        guard let navigationRequest,
              let heading = headings.first(where: { $0.id == navigationRequest.headingID })
        else { return nil }
        return MarkdownTextScrollRequest(
            id: navigationRequest.id,
            utf16Offset: heading.sourceOffset,
            animated: navigationRequest.animated
        )
    }

    private var plainFallback: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])
    }

    private func compile() async {
        let source = text
        let size = fontSize
        let result = await Task.detached(priority: .userInitiated) { () -> CompiledMarkdown in
            var compiler = SemiRenderedMarkdownCompiler()
            compiler.fontSize = size
            return CompiledMarkdown(attributedString: compiler.attributedString(for: source))
        }.value
        guard !Task.isCancelled else { return }
        compiled = result.attributedString
    }

    private struct CompileKey: Equatable {
        let text: String
        let fontSize: CGFloat
    }

    /// Carries the compiled string back to the main actor.
    ///
    /// `NSAttributedString` is not `Sendable`, but this instance is built inside the compile task,
    /// never mutated, and never touched again by it — handing it over is a transfer, not sharing.
    private struct CompiledMarkdown: @unchecked Sendable {
        let attributedString: NSAttributedString
    }
}

// MARK: - Fully rendered Markdown surface

/// Preview-only rendered compiler. This is intentionally separate from `EnhancedMarkdownView` so
/// chat rendering never receives an asset root, image hook, embed rewrite, or navigation state.
private struct AgentRenderedMarkdownView: View {
    let text: String
    let document: AgentPreviewResolvedDocument
    let rootRelativePaths: [String]
    let rootPathSignature: Int
    let maximumImageDisplayWidth: CGFloat
    let navigationRequest: AgentMarkdownHeadingNavigationRequest?
    let linkOpener: MarkdownFileLinkOpener?

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var compiled: NSAttributedString?

    private var fontSize: CGFloat {
        CGFloat(fontScale.preset.rawValue)
    }

    var body: some View {
        AttributedTextView(
            attributedString: compiled ?? plainFallback,
            isEditable: false,
            allowsTextSelection: true,
            linkOpener: linkOpener,
            scrollRequest: textScrollRequest
        )
        .task(id: compileKey) {
            await compile()
        }
    }

    private var compileKey: CompileKey {
        CompileKey(
            text: text,
            documentPath: document.fileURL.path,
            rootPathSignature: rootPathSignature,
            fontSize: fontSize,
            maximumImageDisplayWidth: maximumImageDisplayWidth
        )
    }

    private var textScrollRequest: MarkdownTextScrollRequest? {
        guard let navigationRequest, let compiled else { return nil }
        let offsets = RenderedMarkdownHeadingAnchorMapper.offsets(in: compiled)
        guard let offset = offsets[navigationRequest.headingID] else { return nil }
        return MarkdownTextScrollRequest(
            id: navigationRequest.id,
            utf16Offset: offset,
            animated: navigationRequest.animated
        )
    }

    private var plainFallback: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])
    }

    private func compile() async {
        let source = text
        let size = fontSize
        let width = maximumImageDisplayWidth
        let paths = rootRelativePaths
        let relativeDocumentPath = document.reference.relativePath
        let imageProvider = AgentPreviewMarkdownImageProvider(document: document).enhancedProvider()

        let worker = Task.detached(priority: .userInitiated) { () -> CompiledMarkdown in
            guard !Task.isCancelled else {
                return CompiledMarkdown(attributedString: NSAttributedString())
            }
            let resolver = WikiLinkResolver(rootRelativePaths: paths)
            let renderedSource = ObsidianEmbedProcessor.renderedMarkdown(
                from: source,
                resolver: resolver,
                documentRelativePath: relativeDocumentPath
            )
            let markdown = Document(parsing: renderedSource, options: [.disableSmartOpts])
            var compiler = EnhancedMarkdownCompiler()
            compiler.fontSize = size
            compiler.imageProvider = imageProvider
            compiler.maximumImageDisplayWidth = width
            compiler.indexesHeadingsForNavigation = true
            let attributed = Self.quietEmbeddedNoteLinks(
                compiler.attributedString(from: markdown)
            )
            return CompiledMarkdown(attributedString: attributed)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        compiled = result.attributedString
    }

    private struct CompileKey: Equatable {
        let text: String
        let documentPath: String
        let rootPathSignature: Int
        let fontSize: CGFloat
        let maximumImageDisplayWidth: CGFloat
    }

    private struct CompiledMarkdown: @unchecked Sendable {
        let attributedString: NSAttributedString
    }

    private nonisolated static func quietEmbeddedNoteLinks(_ source: NSAttributedString) -> NSAttributedString {
        let result = source.mutableCopy() as! NSMutableAttributedString
        let fullRange = NSRange(location: 0, length: result.length)
        var noteRanges: [NSRange] = []
        result.enumerateAttribute(.markdownRawLink, in: fullRange) { value, range, _ in
            guard value != nil,
                  result.attributedSubstring(from: range).string.hasPrefix("Embedded note:")
            else { return }
            noteRanges.append(range)
        }
        for range in noteRanges {
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        return result
    }
}

// MARK: - Outline popover

private struct AgentMarkdownOutlinePopover: View {
    let headings: [MarkdownOutlineHeading]
    let onSelect: (MarkdownOutlineHeading) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @FocusState private var focusedHeadingID: Int?

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(headings) { heading in
                    Button {
                        onSelect(heading)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("H\(heading.level)")
                                .font(preset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)

                            Text(heading.title)
                                .font(outlineFont(for: heading.level))
                                .foregroundStyle(heading.level == 1 ? .primary : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(heading.level - 1) * preset.scaledMetric(10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedHeadingID, equals: heading.id)
                    .accessibilityLabel("Heading level \(heading.level), \(heading.title)")
                }
            }
            .padding(.vertical, 6)
        }
        .frame(
            width: preset.scaledMetric(260),
            height: min(preset.scaledMetric(320), CGFloat(headings.count * 30 + 12))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document outline")
        .onAppear { focusedHeadingID = headings.first?.id }
        .onMoveCommand(perform: moveFocus)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !headings.isEmpty else { return }
        let currentIndex = focusedHeadingID.flatMap { id in
            headings.firstIndex(where: { $0.id == id })
        } ?? 0
        switch direction {
        case .up:
            focusedHeadingID = headings[max(0, currentIndex - 1)].id
        case .down:
            focusedHeadingID = headings[min(headings.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    private func outlineFont(for level: Int) -> Font {
        switch level {
        case 1:
            preset.swiftUIFont(sizeAtNormal: 11.5, weight: .semibold)
        case 2:
            preset.swiftUIFont(sizeAtNormal: 11, weight: .medium)
        case 3:
            preset.swiftUIFont(sizeAtNormal: 10.5, weight: .regular)
        default:
            preset.swiftUIFont(sizeAtNormal: 10, weight: .regular)
        }
    }
}

// MARK: - Shared chrome

/// A centred message with an optional action, used for every non-reading state.
private struct AgentPreviewMessageView: View {
    let symbolName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var preset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: preset.scaledMetric(22), weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)

            Text(title)
                .font(preset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(preset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .agentSidebarCard()
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

/// A one-line, self-dismissing notice pinned under the document.
private struct AgentPreviewInlineNoticeView: View {
    let message: String

    @ObservedObject private var fontScale = FontScaleManager.shared

    private enum Layout {
        static let glyphSizeAtNormal: CGFloat = 9
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: fontScale.preset.scaledMetric(Layout.glyphSizeAtNormal)))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(fontScale.preset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presentation helpers

extension AgentSessionArtifactKind {
    var badgeLabel: String {
        switch self {
        case .markdown: "MD"
        case .html: "HTML"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .markdown: "Markdown document"
        case .html: "HTML document"
        }
    }

    var symbolName: String {
        switch self {
        case .markdown: "doc.text"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension AgentPreviewResolutionFailure {
    var title: String {
        switch self {
        case .unknownRoot: "Folder No Longer Loaded"
        case .emptyPath: "No Document"
        case .unsupportedKind: "Not Previewable"
        case .outsideScope: "Outside This Checkout"
        }
    }

    var symbolName: String {
        switch self {
        case .unknownRoot: "folder.badge.questionmark"
        case .emptyPath: "doc"
        case .unsupportedKind: "doc.questionmark"
        case .outsideScope: "lock.shield"
        }
    }

    func message(for reference: PreviewDocumentReference) -> String {
        switch self {
        case .unknownRoot:
            "\(reference.fileName) belongs to a folder that is no longer part of this workspace."
        case .emptyPath:
            "This reference does not name a file."
        case let .unsupportedKind(fileExtension):
            fileExtension.isEmpty
                ? "The preview reads Markdown and HTML documents."
                : "The preview reads Markdown and HTML documents, not .\(fileExtension) files."
        case .outsideScope:
            """
            \(reference.relativePath) resolves to a location outside the checkout it belongs to, \
            so the preview refused to open it.
            """
        }
    }
}
