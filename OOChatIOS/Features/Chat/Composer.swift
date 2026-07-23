import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isPromptFocused: Bool
    @State private var showModeMenu = false
    @State private var sheetHeight: CGFloat = 400
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var isImportingPhotos = false
    @State private var isFileImporterPresented = false
    @State private var isImportingFiles = false
    @State private var fileImportConversationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.stackSpacing) {
            if viewModel.shouldShowSlashSkillPicker {
                skillPicker
            }

            if !viewModel.pendingImages.isEmpty {
                pendingImageStrip
            }
            if !viewModel.pendingFiles.isEmpty {
                pendingFileStrip
            }

            modeMenu
                .padding(.leading, ComposerMetrics.modeLeadingPadding)

            inputBar
        }
        .padding(.horizontal, ComposerMetrics.outerHorizontalPadding)
        .padding(.bottom, ComposerMetrics.outerBottomPadding)
        .frame(maxWidth: ChatReadableWidth.maximum)
        .frame(maxWidth: .infinity)
        .onChange(of: viewModel.prompt) {
            viewModel.promptDidChange()
        }
        .onChange(of: viewModel.activeConversationID) {
            isPromptFocused = viewModel.activeConversationID != nil
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else {
                return
            }
            let conversationID = viewModel.activeConversationID
            Task {
                await importSelectedPhotos(items, for: conversationID)
            }
        }
        .onAppear {
            viewModel.prefetchActiveAgentSkills()
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(
                1,
                ChatImageAttachment.maximumCount - viewModel.pendingImages.count
            ),
            matching: .images
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            let conversationID = fileImportConversationID
            fileImportConversationID = nil
            switch result {
            case .success(let urls):
                Task {
                    await importSelectedFiles(urls, for: conversationID)
                }
            case .failure(let error):
                viewModel.reportFileImportFailure(error)
            }
        }
    }

    private var skillPicker: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.slashSkillSuggestions) { skill in
                    Button {
                        viewModel.selectSlashSkill(skill)
                        isPromptFocused = true
                    } label: {
                        skillRow(skill)
                    }
                    .buttonStyle(SkillSuggestionButtonStyle())

                    if skill.id != viewModel.slashSkillSuggestions.last?.id {
                        Divider()
                            .padding(.leading, ComposerMetrics.skillDividerInset)
                    }
                }
            }
        }
        .frame(height: skillPickerHeight)
        .scrollIndicators(.hidden)
        .glassBackground(
            in: skillPickerShape,
            tint: Color(.secondarySystemBackground).opacity(ComposerMetrics.skillPickerGlassTintOpacity),
            fallback: Color(.secondarySystemBackground)
        )
        .overlay {
            skillPickerShape
                .stroke(Color(.systemBackground).opacity(ComposerMetrics.skillPickerHighlightOpacity), lineWidth: 0.9)
        }
        .overlay {
            skillPickerShape
                .stroke(Color(.separator).opacity(ComposerMetrics.skillPickerStrokeOpacity), lineWidth: 0.6)
        }
        .clipShape(skillPickerShape)
        .shadow(
            color: .black.opacity(ComposerMetrics.skillPickerShadowOpacity),
            radius: ComposerMetrics.skillPickerShadowRadius,
            y: ComposerMetrics.skillPickerShadowYOffset
        )
        .accessibilityLabel("Available skills")
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack(alignment: .top, spacing: ComposerMetrics.skillRowSpacing) {
            Image(systemName: "command")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: ComposerMetrics.skillIconSize, height: ComposerMetrics.skillIconSize)
                .background(
                    AppTheme.primary.opacity(ComposerMetrics.skillIconBackgroundOpacity),
                    in: RoundedRectangle(cornerRadius: ComposerMetrics.skillIconCornerRadius, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("/\(skill.name)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .lineLimit(2)
                }
            }
            .padding(.top, ComposerMetrics.skillTextTopPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ComposerMetrics.skillRowHorizontalPadding)
        .padding(.vertical, ComposerMetrics.skillRowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Insert this skill in the message field")
    }

    private var skillPickerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ComposerMetrics.skillPickerCornerRadius, style: .continuous)
    }

    private var skillPickerHeight: CGFloat {
        let rowCount = CGFloat(viewModel.slashSkillSuggestions.count)
        return min(
            rowCount * ComposerMetrics.skillRowEstimatedHeight,
            ComposerMetrics.skillPickerMaxHeight
        )
    }

    private var inputBar: some View {
        HStack(alignment: .center, spacing: ComposerMetrics.inputSpacing) {
            attachmentMenu

            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .tint(AppTheme.primary)
                .frame(minHeight: ComposerMetrics.sendButtonSize, alignment: .center)
                .padding(.vertical, ComposerMetrics.inputVerticalPadding)

            sendButton
        }
        .padding(.leading, ComposerMetrics.horizontalPadding)
        .padding(.trailing, ComposerMetrics.trailingPadding)
        .padding(.vertical, ComposerMetrics.verticalPadding)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
                .stroke(
                    isPromptFocused
                        ? AppTheme.primary.opacity(ComposerMetrics.focusedInputStrokeOpacity)
                        : Color(.separator).opacity(ComposerMetrics.inputStrokeOpacity),
                    lineWidth: isPromptFocused ? 1 : 0.5
                )
        )
        .shadow(
            color: AppTheme.primary.opacity(isPromptFocused ? ComposerMetrics.focusedInputShadowOpacity : 0),
            radius: ComposerMetrics.focusedInputShadowRadius,
            y: ComposerMetrics.focusedInputShadowYOffset
        )
        .animation(AppMotion.press, value: isPromptFocused)
    }

    private var attachmentMenu: some View {
        Menu {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Upload Photo", systemImage: "photo")
            }
            .disabled(
                viewModel.pendingImages.count >= ChatImageAttachment.maximumCount
                    || isImportingPhotos
            )

            Button {
                fileImportConversationID = viewModel.activeConversationID
                isFileImporterPresented = true
            } label: {
                Label("Upload File", systemImage: "doc")
            }
            .disabled(
                viewModel.pendingFiles.count >= ChatFileAttachment.maximumCount
                    || isImportingFiles
            )
        } label: {
            Group {
                if isImportingPhotos || isImportingFiles {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                }
            }
            .foregroundStyle(AppTheme.primary)
            .frame(width: ComposerMetrics.attachmentButtonSize, height: ComposerMetrics.attachmentButtonSize)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(
            viewModel.activeConversation == nil
                || isImportingPhotos
                || isImportingFiles
                || (
                    viewModel.pendingImages.count >= ChatImageAttachment.maximumCount
                        && viewModel.pendingFiles.count >= ChatFileAttachment.maximumCount
                )
        )
        .accessibilityLabel(
            isImportingPhotos || isImportingFiles
                ? "Loading attachments"
                : "Add attachment"
        )
    }

    private var pendingImageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ComposerMetrics.attachmentSpacing) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.element.id) { index, image in
                    if let uiImage = UIImage(data: image.data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: ComposerMetrics.attachmentPreviewSize,
                                    height: ComposerMetrics.attachmentPreviewSize
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                        style: .continuous
                                    )
                                )

                            Button {
                                viewModel.removePendingImage(id: image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.72))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                        .padding(.top, 5)
                        .padding(.trailing, 5)
                    }
                }
            }
            .padding(.horizontal, ComposerMetrics.modeLeadingPadding)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Selected photos")
    }

    private var pendingFileStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ComposerMetrics.attachmentSpacing) {
                ForEach(Array(viewModel.pendingFiles.enumerated()), id: \.element.id) { index, file in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .font(.title3)
                                .foregroundStyle(AppTheme.primary)
                                .frame(width: 34, height: 34)
                                .background(
                                    AppTheme.primary.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(Self.fileSizeLabel(file.data.count))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(width: ComposerMetrics.filePreviewWidth, height: ComposerMetrics.filePreviewHeight)
                        .background(
                            Color(.secondarySystemBackground),
                            in: RoundedRectangle(
                                cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                style: .continuous
                            )
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Selected file \(file.name), \(Self.fileSizeLabel(file.data.count))")

                        Button {
                            viewModel.removePendingFile(id: file.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove file \(index + 1)")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
            .padding(.horizontal, ComposerMetrics.modeLeadingPadding)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Selected files")
    }

    private func importSelectedPhotos(
        _ items: [PhotosPickerItem],
        for conversationID: String?
    ) async {
        isImportingPhotos = true
        defer {
            selectedPhotoItems = []
            isImportingPhotos = false
        }

        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PhotoImportError.noData
                }
                let mimeType = item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .preferredMIMEType ?? "image/jpeg"
                _ = viewModel.addPendingImage(
                    data: data,
                    mimeType: mimeType,
                    to: conversationID
                )
            } catch {
                viewModel.reportImageImportFailure(error)
            }
        }
    }

    private func importSelectedFiles(
        _ urls: [URL],
        for conversationID: String?
    ) async {
        isImportingFiles = true
        defer { isImportingFiles = false }

        let selectedURLs = urls.prefix(ChatFileAttachment.maximumCount)
        for url in selectedURLs {
            do {
                let imported = try await Self.loadFile(at: url)
                _ = viewModel.addPendingFile(
                    name: imported.name,
                    data: imported.data,
                    mimeType: imported.mimeType,
                    to: conversationID
                )
            } catch {
                viewModel.reportFileImportFailure(error)
            }
        }

        if urls.count > selectedURLs.count {
            viewModel.reportFileImportFailure(FileImportError.tooMany)
        }
    }

    private static func loadFile(at url: URL) async throws -> (name: String, data: Data, mimeType: String) {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try url.resourceValues(forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isRegularFileKey,
                .nameKey,
            ])
            guard values.isRegularFile != false else {
                throw FileImportError.notARegularFile
            }
            if let fileSize = values.fileSize,
               fileSize > ChatFileAttachment.maximumByteCount {
                throw FileImportError.tooLarge
            }
            return (
                name: values.name ?? url.lastPathComponent,
                data: try Data(contentsOf: url, options: .mappedIfSafe),
                mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream"
            )
        }.value
    }

    private static func fileSizeLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var modeMenu: some View {
        Button {
            showModeMenu = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.activeMode.icon)
                    .foregroundStyle(AppTheme.primary)

                Text(viewModel.activeMode.label)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, ComposerMetrics.modeHorizontalPadding)
            .padding(.vertical, ComposerMetrics.modeVerticalPadding)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(.separator).opacity(ComposerMetrics.modeStrokeOpacity), lineWidth: 0.5)
            }
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.96, pressedOpacity: 0.88))
        .disabled(viewModel.activeConversation == nil || viewModel.isProcessing)
        .accessibilityLabel("Chat mode: \(viewModel.activeMode.label)")
        .popover(isPresented: $showModeMenu) {
            modeSheet
                .frame(idealWidth: ComposerMetrics.modePopoverWidth)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.height(sheetHeight)])
                .presentationDragIndicator(.visible)
        }
    }

    private var modeSheet: some View {
        VStack(spacing: 0) {
            Text("Response Mode")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(ChatMode.allCases) { mode in
                Button {
                    viewModel.setMode(mode)
                    showModeMenu = false
                } label: {
                    modeRow(for: mode)
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.86))
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sheetHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        sheetHeight = newValue
                    }
            }
        }
    }

    private func modeRow(for mode: ChatMode) -> some View {
        HStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(
                    AppTheme.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(mode.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if viewModel.activeMode == mode {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.92).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var sendButton: some View {
        Button {
            if viewModel.isProcessing {
                viewModel.stopActiveResponse()
            } else {
                viewModel.sendPrompt()
                isPromptFocused = false
            }
        } label: {
            Image(systemName: viewModel.isProcessing ? "stop.fill" : "arrow.up")
                .font(viewModel.isProcessing ? .caption.weight(.bold) : .body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: ComposerMetrics.sendButtonSize, height: ComposerMetrics.sendButtonSize)
                .glassBackground(
                    in: Circle(),
                    interactive: true,
                    tint: AppTheme.primary
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.92, pressedOpacity: 0.90))
        .disabled(
            !viewModel.isProcessing
                && viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.pendingImages.isEmpty
                && viewModel.pendingFiles.isEmpty
        )
        .accessibilityLabel(viewModel.isProcessing ? "Stop response" : "Send message")
    }

}

private enum ComposerMetrics {
    static let outerHorizontalPadding: CGFloat = 12
    static let outerBottomPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 27
    static let stackSpacing: CGFloat = 9
    static let inputSpacing: CGFloat = 10
    static let inputVerticalPadding: CGFloat = 2
    static let inputStrokeOpacity: Double = 0.10
    static let focusedInputStrokeOpacity: Double = 0.32
    static let focusedInputShadowOpacity: Double = 0.08
    static let focusedInputShadowRadius: CGFloat = 10
    static let focusedInputShadowYOffset: CGFloat = 2
    static let modeLeadingPadding: CGFloat = 8
    static let modeHorizontalPadding: CGFloat = 10
    static let modeVerticalPadding: CGFloat = 5
    static let modeStrokeOpacity: Double = 0.08
    static let modePopoverWidth: CGFloat = 340
    static let sendButtonSize: CGFloat = 40
    static let attachmentButtonSize: CGFloat = 32
    static let attachmentPreviewSize: CGFloat = 72
    static let attachmentCornerRadius: CGFloat = 14
    static let attachmentSpacing: CGFloat = 8
    static let filePreviewWidth: CGFloat = 190
    static let filePreviewHeight: CGFloat = 62
    static let skillPickerMaxHeight: CGFloat = 260
    static let skillPickerCornerRadius: CGFloat = 24
    static let skillPickerGlassTintOpacity: Double = 0.78
    static let skillPickerHighlightOpacity: Double = 0.70
    static let skillPickerStrokeOpacity: Double = 0.22
    static let skillPickerShadowOpacity: Double = 0.13
    static let skillPickerShadowRadius: CGFloat = 30
    static let skillPickerShadowYOffset: CGFloat = 10
    static let skillRowSpacing: CGFloat = 12
    static let skillRowEstimatedHeight: CGFloat = 82
    static let skillRowHorizontalPadding: CGFloat = 14
    static let skillRowVerticalPadding: CGFloat = 12
    static let skillIconSize: CGFloat = 34
    static let skillIconCornerRadius: CGFloat = 9
    static let skillIconBackgroundOpacity: Double = 0.08
    static let skillTextTopPadding: CGFloat = 1
    static let skillDividerInset: CGFloat = 60
}

private enum PhotoImportError: LocalizedError {
    case noData

    var errorDescription: String? {
        "The selected photo contained no readable data."
    }
}

private enum FileImportError: LocalizedError {
    case notARegularFile
    case tooLarge
    case tooMany

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "Please choose a regular file."
        case .tooLarge:
            return "The selected file is larger than 10 MB."
        case .tooMany:
            return "You can attach up to 10 files."
        }
    }
}

private struct SkillSuggestionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.tertiarySystemFill) : Color.clear)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

// Presentation details for each mode, kept out of the model layer.
private extension ChatMode {
    var icon: String {
        switch self {
        case .safe:
            return "shield"
        case .plan:
            return "list.bullet.clipboard"
        case .accept:
            return "checkmark.circle"
        case .ulw:
            return "bolt.fill"
        }
    }

    var detail: String {
        switch self {
        case .safe:
            return "Ask before file edits and commands"
        case .plan:
            return "Research first, then review the plan"
        case .accept:
            return "Trust the agent to edit without asking"
        case .ulw:
            return "Work autonomously for up to 100 turns"
        }
    }
}
