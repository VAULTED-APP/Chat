//
//  ChatView.swift
//  Chat
//
//  Created by Alisa Mylnikova on 20.04.2022.
//

import SwiftUI
import PhotosUI
import GiphyUISDK
import ExyteMediaPicker

public typealias MediaPickerLiveCameraStyle = LiveCameraCellStyle
public typealias MediaPickerSelectionParameters = SelectionParameters

public enum ChatType: CaseIterable, Sendable {
    case conversation // the latest message is at the bottom, new messages appear from the bottom
    case comments // the latest message is at the top, new messages appear from the top
}

public enum ReplyMode: CaseIterable, Sendable {
    case quote // when replying to message A, new message will appear as the newest message, quoting message A in its body
    case answer // when replying to message A, new message with appear direclty below message A as a separate cell without duplicating message A in its body
}

/// Controls which `Date` is exposed on each `MessagesSection` and therefore drives the
/// section header / `dateHeaderBuilder` callback.
public enum SectionHeaderTimestampMode: CaseIterable, Sendable {
    /// Use the start of the day (midnight) of the section. Default — useful when the
    /// section header is purely a date label (e.g. "Today", "Yesterday", "Mar 12, 2026").
    case startOfDay
    /// Use the timestamp of the first activity (earliest `createdAt`) in that section.
    /// Useful when the section header should display the time the conversation/day
    /// actually started rather than midnight.
    case firstActivity
}

public struct ChatView<MessageContent: View, InputViewContent: View, MenuAction: MessageMenuAction>: View {
    
    /// User and MessageId
    public typealias TapAvatarClosure = (User, String) -> ()
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatTheme) private var theme
    @Environment(\.giphyConfig) private var giphyConfig

    // MARK: - Parameters

    /// provide custom message view builder
    /// To customize only some messages while keeping the default style for others,
    /// use `messageBuilder` and return your custom view for the messages you want to style, and `params.defaultMessageView()` for the rest.
    /// This way you can mix your custom message view with ExyteChat's built-in styling in the same chat.
    /// ```swift
    /// ChatView(messages: viewModel.messages) { draft in
    ///     viewModel.send(draft: draft)
    /// } messageBuilder: { params in
    ///     if needsCustomUI(params.message) {
    ///         MyCustomMessageView(message: params.message)
    ///     } else {
    ///         params.defaultMessageView()
    ///     }
    /// }
    /// ```
    @ViewBuilder var messageBuilder: MessageBuilderParamsClosure

    /// provide custom input view builder
    @ViewBuilder var inputViewBuilder: InputViewBuilderParamsClosure

    /// message menu customization: create enum complying to MessageMenuAction and pass a closure processing your enum cases
    var messageMenuAction: MessageMenuActionClosure

    var type: ChatType
    var sections: [MessagesSection]
    var ids: [String]
    var didSendMessage: (DraftMessage) -> Void
    var didUpdateAttachmentStatus: ((AttachmentUploadUpdate) -> Void)?

    // MARK: - Simple view builders

    /// a header for the whole chat, which will scroll together with all the messages and headers
    var mainHeaderBuilder: (()->AnyView)?

    /// date section header builder
    var dateHeaderBuilder: ((Date)->AnyView)?

    /// content to display in between the chat list view and the input view
    var betweenListAndInputViewBuilder: (()->AnyView)?

    /// content to display in place of the chat list when there are no messages.
    /// The closure receives the current `Date` (evaluated at render time), which can be
    /// used to show contextual empty-state copy (e.g. "No messages today").
    var emptyViewBuilder: (()->AnyView)?

    // MARK: - Customization

    var chatCustomizationParameters = ChatCustomizationParameters()
    var messageCustomizationParameters = MessageCustomizationParameters()
    var inputViewCustomizationParameters = InputViewCustomizationParameters()

    // MARK: - State

    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var inputViewModel = InputViewModel()
    @StateObject private var globalFocusState = GlobalFocusState()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var keyboardState = KeyboardState()

    @State private var isScrolledToBottom: Bool = true
    @State private var shouldScrollToTop: () -> () = {}

    /// Used to prevent the MainView from responding to keyboard changes while the Menu is active
    @State private var isShowingMenu = false

    @State private var tableContentHeight: CGFloat = 0
    @State private var inputViewSize = CGSize.zero
    @State private var timeViewSize = CGSize.zero
    @State private var reactionViewSize = CGSize.zero
    @State private var cellFrames = [String: CGRect]()

    @State private var giphyConfigured = false
    @State private var selectedGiphyMedia: GPHMedia? = nil

    /// Tracks the most recent non-zero keyboard height (excluding bottom safe
    /// area) so we can size the inline `PhotosPicker` sheet detent and pad the
    /// input view to keep the layout stable while toggling between keyboard
    /// and picker.
    @State private var storedKeyboardHeight: CGFloat = 0

    /// Externally-owned selection for the inline `PhotosPicker` sheet. The
    /// consumer holds the source of truth (typically a `@State` array) and
    /// passes it in via `.selectedPhotoPickerItems($items)`. The binding is
    /// also forwarded to the custom input view through
    /// `InputViewBuilderParameters` so it can render staged thumbnails and
    /// remove items.
    var selectedPhotoPickerItemsBinding: Binding<[PhotosPickerItem]> = .constant([])

    /// Externally-owned index of the staged image currently presented in a
    /// fullscreen gallery. The consumer controls when to show/hide the
    /// gallery by mutating this binding, and provides the gallery view via
    /// `galleryFullScreenCoverContent`.
    var galleryInitialIndexBinding: Binding<Int?> = .constant(nil)

    /// Builder for the consumer-provided fullscreen gallery view. `ChatView`
    /// attaches it both inside the `PhotosPicker` sheet and on the root,
    /// with mutual exclusion driven by `inputViewModel.showPicker`, so the
    /// gallery covers the picker when it's open and the chat otherwise.
    var galleryFullScreenCoverContent: ((Int) -> AnyView)?

    /// Fallback when we haven't observed a keyboard frame yet (first cold
    /// presentation of the picker before the keyboard has ever opened).
    private var keyboardHeight: CGFloat {
        storedKeyboardHeight == 0 ? 300 : storedKeyboardHeight
    }

    private var animatedKeyboardHeight: CGFloat {
        (inputViewModel.showPicker || keyboardState.isShown) ? keyboardHeight : 0
    }

    public var body: some View {
        mainView
            .background(chatBackground())
            .environmentObject(keyboardState)
            .ignoresSafeArea(.keyboard, edges: .all)
            .onChange(of: inputViewModel.text) { _ , newValue in
                inputViewCustomizationParameters.onInputTextChange?(newValue)
            }
            .onChange(of: inputViewCustomizationParameters.externalInputText) {
                DispatchQueue.main.async {
                    inputViewModel.text = inputViewCustomizationParameters.externalInputText ?? ""
                }
            }
            .onChange(of: keyboardState.keyboardFrame) { _, frame in
                guard frame != .zero, storedKeyboardHeight == 0 else { return }
                storedKeyboardHeight = max(frame.height - bottomSafeAreaInset, 0)
            }
            .onChange(of: inputViewModel.showPicker) { _ , newValue in
                if newValue {
                    globalFocusState.focus = nil
                }
            }
            .onChange(of: keyboardState.isShown) { _, newValue in
                if newValue {
                    inputViewModel.showPicker = false
                }
            }
            .sheet(isPresented: $inputViewModel.showPicker) {
                photoPickerSheet
                    .fullScreenCover(item: galleryPresentationBinding) { presentation in
                        galleryFullScreenCoverContent?(presentation.initialIndex)
                    }
            }
            .background {
                // assume all the time views have same width, like "00:00"
                if let anyMessage = sections.first?.rows.first?.message, timeViewSize == .zero {
                    FinalMeasuringTrickView(size: $timeViewSize) {
                        MessageTimeView(text: anyMessage.time, userType: anyMessage.user.type)
                    }
                }
                if let anyMessage = sections.first?.rows.first?.message, reactionViewSize == .zero {
                    FinalMeasuringTrickView(size: $reactionViewSize) {
                        ReactionBubble(reaction: Reaction(id: "0", user: anyMessage.user, createdAt: anyMessage.createdAt, type: .emoji("🙃️️️️"), status: .sent), font: messageCustomizationParameters.font)
                    }
                }
            }
    }
    
    var mainView: some View {
        VStack(spacing: 0) {
            if chatCustomizationParameters.showNetworkConnectionProblem, !networkMonitor.isConnected {
                waitingForNetwork
            }
            
            if chatCustomizationParameters.isListAboveInputView {
                ZStack(alignment: .bottom) {
                    listWithButton
                    VStack(spacing: 0) {
                        if let builder = betweenListAndInputViewBuilder {
                            builder()
                        }
                        inputView
                    }
                }
            } else {
                inputView
                if let builder = betweenListAndInputViewBuilder {
                    builder()
                }
                listWithButton
            }
        }
        // Used to prevent ChatView movement during Emoji Keyboard invocation
        .ignoresSafeArea(isShowingMenu ? .keyboard : [])
    }
    
    var waitingForNetwork: some View {
        VStack {
            Rectangle()
                .foregroundColor(theme.colors.mainText.opacity(0.12))
                .frame(height: 1)
            HStack {
                Spacer()
                Image("waiting", bundle: .current)
                Text(chatCustomizationParameters.localization.waitingForNetwork)
                Spacer()
            }
            .padding(.top, 6)
            Rectangle()
                .foregroundColor(theme.colors.mainText.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.top, 8)
    }
    
    @ViewBuilder
    var listWithButton: some View {
        switch type {
        case .conversation:
            ZStack(alignment: .bottomTrailing) {
                list

                if chatCustomizationParameters.showScrollToBottomButton, !isScrolledToBottom {
                    Button {
                        NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
                    } label: {
                        theme.images.scrollToBottom
                            .frame(width: 40, height: 40)
                            .circleBackground(theme.colors.messageFriendBG)
                            .foregroundStyle(theme.colors.sendButtonBackground)
                            .shadow(color: .primary.opacity(0.1), radius: 2, y: 1)
                    }
                    .padding(.trailing, MessageView.horizontalScreenEdgePadding)
                    .padding(.bottom, 8)
                }
            }
            
        case .comments:
            list
        }
    }
    
    @ViewBuilder
    var list: some View {
        UIList(
            // MARK: - Core

            viewModel: viewModel,
            inputViewModel: inputViewModel,

            isScrolledToBottom: $isScrolledToBottom,
            shouldScrollToTop: $shouldScrollToTop,
            tableContentHeight: $tableContentHeight,

            // MARK: - View builders

            messageBuilder: messageBuilder,
            mainHeaderBuilder: mainHeaderBuilder,
            dateHeaderBuilder: dateHeaderBuilder,

            // MARK: - Data / type

            type: type,
            sections: sections,
            ids: ids,

            // MARK: - Customization

            chatParams: chatCustomizationParameters,
            messageParams: messageCustomizationParameters,
            timeViewWidth: $timeViewSize.width,
            reactionViewWidth: $reactionViewSize.width,
            bottomOverlayInset: chatCustomizationParameters.isListAboveInputView
                ? inputViewSize.height + animatedKeyboardHeight + 10
                : 0
        )
        .applyIf(!chatCustomizationParameters.isScrollEnabled) {
            $0.frame(height: tableContentHeight)
        }
        .overlay {
            if isChatEmpty, let emptyViewBuilder {
                emptyViewBuilder()
            }
        }
        .onStatusBarTap {
            shouldScrollToTop()
        }
        .transparentNonAnimatingFullScreenCover(item: $viewModel.messageMenuRow) {
            if let row = viewModel.messageMenuRow {
                messageMenu(row)
                    .onAppear(perform: showMessageMenu)
            }
        }
        .onPreferenceChange(MessageMenuPreferenceKey.self) { frames in
            DispatchQueue.main.async {
                if self.cellFrames != frames {
                    self.cellFrames = frames
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                inputViewModel.showPicker = false
                globalFocusState.focus = nil
            }
        )
        .onAppear {
            viewModel.didSendMessage = didSendMessage
            viewModel.inputViewModel = inputViewModel
            viewModel.globalFocusState = globalFocusState
            if let didUpdateAttachmentStatus {
                viewModel.didUpdateAttachmentStatus = didUpdateAttachmentStatus
            }

            inputViewModel.didSendMessage = { [didSendMessage, type] value in
                Task { @MainActor in
                    didSendMessage(value)
                }
                if type == .conversation {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
                    }
                }
            }
        }
    }

    var inputView: some View {
        inputViewBuilder(
            InputViewBuilderParameters(
                text: $inputViewModel.text,
                attachments: inputViewModel.attachments,
                inputViewState: inputViewModel.state,
                inputViewStyle: .message,
                inputViewActionClosure: inputViewModel.inputViewAction(),
                dismissKeyboardClosure: {
                    globalFocusState.focus = nil
                }
            )
        )
        .customFocus($globalFocusState.focus, equals: .uuid(viewModel.inputFieldId))
        .sizeGetter($inputViewSize)
        .padding(.bottom, animatedKeyboardHeight)
        .animation(.interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: 0), value: animatedKeyboardHeight)
        .environmentObject(globalFocusState)
        .onAppear(perform: inputViewModel.onStart)
        .onDisappear(perform: inputViewModel.onStop)
    }

    @ViewBuilder
    private var photoPickerSheet: some View {
        PhotosPicker(
            "",
            selection: selectedPhotoPickerItemsBinding,
            maxSelectionCount: inputViewCustomizationParameters.mediaPickerParameters.selectionParameters.selectionLimit,
            selectionBehavior: .continuousAndOrdered,
            matching: .images,
            photoLibrary: .shared()
        )
        .photosPickerStyle(.inline)
        .tint(Color.black)
        .photosPickerDisabledCapabilities([.stagingArea, .selectionActions])
        .presentationDetents([.height(keyboardHeight), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(keyboardHeight)))
    }

    /// Identifiable wrapper around the gallery initial index so it can drive
    /// `.fullScreenCover(item:)`.
    private struct GalleryPresentation: Identifiable {
        let initialIndex: Int
        var id: Int { initialIndex }
    }

    /// Binding used inside the picker sheet — always reflects the consumer's
    /// `galleryInitialIndex` so the gallery can sit on top of the picker.
    private var galleryPresentationBinding: Binding<GalleryPresentation?> {
        Binding(
            get: { galleryInitialIndexBinding.wrappedValue.map(GalleryPresentation.init) },
            set: { galleryInitialIndexBinding.wrappedValue = $0?.initialIndex }
        )
    }

    /// Bottom safe-area inset of the active key window. Used to subtract the
    /// home-indicator region from the reported keyboard frame so the picker
    /// detent matches the visible keyboard area.
    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }
    
    func messageMenu(_ row: MessageRow) -> some View {
        let cellFrame = cellFrames[row.id] ?? .zero

        return MessageMenu(
            viewModel: viewModel,
            isShowingMenu: $isShowingMenu,
            message: row.message,
            cellFrame: cellFrame,
            alignment: menuAlignment(row.message, chatType: type),
            positionInUserGroup: row.positionInUserGroup,
            leadingPadding: messageCustomizationParameters.avatarSize + MessageView.horizontalScreenEdgePadding + MessageView.horizontalSpacing,
            trailingPadding: MessageView.statusViewWidth + MessageView.horizontalScreenEdgePadding + MessageView.horizontalSpacing,
            font: messageCustomizationParameters.font,
            animationDuration: chatCustomizationParameters.messageMenuAnimationDuration,
            onAction: menuActionClosure(row.message),
            reactionHandler: MessageMenu.ReactionConfig(
                delegate: chatCustomizationParameters.reactionDelegate,
                didReact: reactionClosure(row.message)
            )
        ) {
            ChatMessageView(
                viewModel: viewModel,
                messageBuilder: messageBuilder,
                row: row,
                chatType: type,
                messageParams: messageCustomizationParameters,
                timeViewWidth: $timeViewSize.width,
                reactionViewWidth: $reactionViewSize.width,
                isDisplayingMessageMenu: true
            )
            .onTapGesture {
                hideMessageMenu()
            }
        }
    }
    
    /// Determines the message menu alignment based on ChatType and message sender.
    private func menuAlignment(_ message: Message, chatType: ChatType) -> MessageMenuAlignment {
        switch chatType {
        case .conversation:
            return message.user.isCurrentUser ? .right : .left
        case .comments:
            return .left
        }
    }
    
    /// Our default reactionCallback flow if the user supports Reactions by implementing the didReactToMessage closure
    private func reactionClosure(_ message: Message) -> (ReactionType?) -> () {
        { reactionType in
            Task { @MainActor in
                // Hide the menu
                hideMessageMenu()
                // Send the draft reaction
                guard let reactionDelegate = chatCustomizationParameters.reactionDelegate, let reactionType else { return }
                reactionDelegate.didReact(to: message, reaction: DraftReaction(messageID: message.id, type: reactionType))
            }
        }
    }

    func menuActionClosure(_ message: Message) -> (MenuAction) -> () {
        { action in
            hideMessageMenu()
            messageMenuAction(action, viewModel.messageMenuAction(), message)
        }
    }

    func showMessageMenu() {
        isShowingMenu = true
    }
    
    func hideMessageMenu() {
        viewModel.messageMenuRow = nil
        viewModel.messageFrame = .zero
        isShowingMenu = false
    }
    
    private func chatBackground() -> some View {
        Group {
            if let background = theme.images.background {
                switch (isLandscape(), colorScheme) {
                case (true, .dark):
                    background.landscapeBackgroundDark
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (true, .light):
                    background.landscapeBackgroundLight
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (false, .dark):
                    background.portraitBackgroundDark
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                case (false, .light):
                    background.portraitBackgroundLight
                        .resizable()
                        .ignoresSafeArea(background.safeAreaRegions, edges: background.safeAreaEdges)
                default:
                    theme.colors.mainBG
                }
            } else {
                theme.colors.mainBG
            }
        }
    }
    
    private func isLandscape() -> Bool {
        UIDevice.current.orientation.isLandscape
    }
    
    private func isGiphyAvailable() -> Bool {
        inputViewCustomizationParameters.availableInputs.contains(AvailableInputType.giphy)
    }

    private var isChatEmpty: Bool {
        sections.allSatisfy { $0.rows.isEmpty }
    }
}

//#Preview {
//    let romeo = User(id: "romeo", name: "Romeo Montague", avatarURL: nil, isCurrentUser: true)
//    let juliet = User(id: "juliet", name: "Juliet Capulet", avatarURL: nil, isCurrentUser: false)
//
//    let monday = try! Date.iso8601Date.parse("2025-05-12")
//    let tuesday = try! Date.iso8601Date.parse("2025-05-13")
//
//    ChatView(messages: [
//        Message(
//            id: "26tb", user: romeo, status: .read, createdAt: monday,
//            text: "And I’ll still stay, to have thee still forget"),
//        Message(
//            id: "zee6", user: romeo, status: .read, createdAt: monday,
//            text: "Forgetting any other home but this"),
//
//        Message(
//            id: "oWUN", user: juliet, status: .read, createdAt: monday,
//            text: "’Tis almost morning. I would have thee gone"),
//        Message(
//            id: "P261", user: juliet, status: .read, createdAt: monday,
//            text: "And yet no farther than a wanton’s bird"),
//        Message(
//            id: "46hu", user: juliet, status: .read, createdAt: monday,
//            text: "That lets it hop a little from his hand"),
//        Message(
//            id: "Gjbm", user: juliet, status: .read, createdAt: monday,
//            text: "Like a poor prisoner in his twisted gyves"),
//        Message(
//            id: "IhRQ", user: juliet, status: .read, createdAt: monday,
//            text: "And with a silken thread plucks it back again"),
//        Message(
//            id: "kwWd", user: juliet, status: .read, createdAt: monday,
//            text: "So loving-jealous of his liberty"),
//
//        Message(
//            id: "9481", user: romeo, status: .read, createdAt: tuesday,
//            text: "I would I were thy bird"),
//
//        Message(
//            id: "dzmY", user: juliet, status: .sent, createdAt: tuesday, text: "Sweet, so would I"),
//        Message(
//            id: "r5HH", user: juliet, status: .sent, createdAt: tuesday,
//            text: "Yet I should kill thee with much cherishing"),
//        Message(
//            id: "quy1", user: juliet, status: .sent, createdAt: tuesday,
//            text: "Good night, good night. Parting is such sweet sorrow"),
//        Message(
//            id: "Mwh6", user: juliet, status: .sent, createdAt: tuesday,
//            text: "That I shall say 'Good night' till it be morrow"),
//    ]) { draft in }
//}
