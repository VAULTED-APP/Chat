//
//  Created by Alex.M on 28.06.2022.
//

import Foundation
import SwiftUI
import PhotosUI
import ExyteChat

@MainActor
struct ChatExampleView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode

    @StateObject var viewModel: ChatExampleViewModel
    var title: String

    @State var text = ""
    @State var scrollToID: String?
    @State private var selectedPhotoPickerItems: [PhotosPickerItem] = []

    let recorderSettings = RecorderSettings(sampleRate: 16000, numberOfChannels: 1, linearPCMBitDepth: 16)
    
    var body: some View {
        ChatView(
            messages: viewModel.messages,
            chatType: .conversation,
            sectionHeaderTimestampMode: .firstActivity,
            didSendMessage: { draft in
                viewModel.send(draft: draft)
            },
            inputViewBuilder: { params in
                ChatInputView(params: params, selectedPhotoPickerItems: $selectedPhotoPickerItems)
            }
        )
        .selectedPhotoPickerItems($selectedPhotoPickerItems)
        .enableLoadMore(offset: 1) {
            viewModel.loadMoreMessages()
        }
        .emptyView {
            Text("Empty State")
        }
        .dateHeaderBuilder { date in
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
        .inputViewText($text)
        .scrollToMessageID(scrollToID)
        .keyboardDismissMode(.none)
        .showUsername(true)
        .setMediaPickerLiveCameraStyle(.prominant)
        .setRecorderSettings(recorderSettings)
        .messageReactionDelegate(viewModel)
        .swipeActions(edge: .leading, performsFirstActionWithFullSwipe: true, items: [
            SwipeAction(action: onReply, activeFor: { !$0.user.isCurrentUser }, background: .blue) {
                VStack {
                    Image(systemName: "arrowshape.turn.up.left")
                        .imageScale(.large)
                        .foregroundStyle(.white)
                        .frame(height: 30)
                    Text("Reply")
                        .foregroundStyle(.white)
                        .font(.footnote)
                }
            }
        ])
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Image("backArrow", bundle: .current)
                        .renderingMode(.template)
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                HStack {
                    if let url = viewModel.chatCover {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                Rectangle().fill(Color(hex: "AFB3B8"))
                            }
                        }
                        .frame(width: 35, height: 35)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 0) {
                            Text(viewModel.chatTitle)
                                .fontWeight(.semibold)
                                .font(.headline)
                                .foregroundStyle(colorScheme == .dark ? .white : .black)
                            Text(viewModel.chatStatus)
                                .font(.footnote)
                                .foregroundColor(Color(hex: "AFB3B8"))
                        }
                        Spacer()
                    }
                }
                .padding(.leading, 10)
            }
        }
        .onAppear(perform: viewModel.onStart)
        .onDisappear(perform: viewModel.onStop)
        .onChange(of: text) { oldValue, newValue in
            print(newValue)
        }
    }
    
    // Swipe Action
    func onReply(message: Message, defaultActions: @escaping (Message, DefaultMessageMenuAction) -> Void) {
        print("Swipe Action - Reply: \(message)")
        // This places the message in the ChatView's InputView ready for the sender to reply
        defaultActions(message, .reply)
    }
}

/// Minimal external input view that demonstrates the inline `PhotosPicker`
/// integration exposed by `ChatView`. It renders staged thumbnails from
/// `params.selectedPhotoPickerItems`, lets the user remove individual images,
/// and forwards the standard `.photo` / `.send` actions through
/// `inputViewActionClosure`.
struct ChatInputView: View {
    let params: InputViewBuilderParameters
    @Binding var selectedPhotoPickerItems: [PhotosPickerItem]

    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selectedPhotoPickerItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedPhotoPickerItems, id: \.self) { item in
                            thumbnailView(for: item)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 64)
            }

            HStack(spacing: 8) {
                Button {
                    params.inputViewActionClosure(.photo)
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                }

                TextField("Message", text: params.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button {
                    params.inputViewActionClosure(.send)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !params.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedPhotoPickerItems.isEmpty
    }

    @ViewBuilder
    private func thumbnailView(for item: PhotosPickerItem) -> some View {
        let key = item.itemIdentifier ?? UUID().uuidString
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = thumbnails[key] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(ProgressView())
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                selectedPhotoPickerItems.removeAll { $0 == item }
                thumbnails[key] = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 4, y: -4)
        }
        .task(id: key) {
            guard thumbnails[key] == nil else { return }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                thumbnails[key] = image
            }
        }
    }
}
