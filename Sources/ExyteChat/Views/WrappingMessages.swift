//
//  SwiftUIView.swift
//  
//
//  Created by Alisa Mylnikova on 06.12.2023.
//

import SwiftUI

extension ChatView {

    nonisolated static func mapMessages(
        _ messages: [Message],
        chatType: ChatType,
        replyMode: ReplyMode,
        sectionHeaderTimestampMode: SectionHeaderTimestampMode = .startOfDay
    ) -> [MessagesSection] {
        guard messages.hasUniqueIDs() else {
            fatalError("Messages can not have duplicate ids, please make sure every message gets a unique id")
        }

        let result: [MessagesSection]
        switch replyMode {
        case .quote:
            result = mapMessagesQuoteModeReplies(
                messages,
                chatType: chatType,
                replyMode: replyMode,
                sectionHeaderTimestampMode: sectionHeaderTimestampMode
            )
        case .answer:
            result = mapMessagesCommentModeReplies(
                messages,
                chatType: chatType,
                replyMode: replyMode,
                sectionHeaderTimestampMode: sectionHeaderTimestampMode
            )
        }

        return result
    }

    nonisolated static func mapMessagesQuoteModeReplies(
        _ messages: [Message],
        chatType: ChatType,
        replyMode: ReplyMode,
        sectionHeaderTimestampMode: SectionHeaderTimestampMode = .startOfDay
    ) -> [MessagesSection] {
        let dates = Set(messages.map({ $0.createdAt.startOfDay() }))
            .sorted()
            .reversed()
        var result: [MessagesSection] = []

        for date in dates {
            let dayMessages = messages.filter({ $0.createdAt.isSameDay(date) })
            let resolvedDate = resolveSectionDate(
                forDay: date,
                messages: dayMessages,
                mode: sectionHeaderTimestampMode
            )
            let section = MessagesSection(
                date: resolvedDate,
                // use fake isFirstSection/isLastSection because they are not needed for quote replies
                rows: wrapSectionMessages(dayMessages, chatType: chatType, replyMode: replyMode, isFirstSection: false, isLastSection: false)
            )
            result.append(section)
        }

        return result
    }

    nonisolated static func mapMessagesCommentModeReplies(
        _ messages: [Message],
        chatType: ChatType,
        replyMode: ReplyMode,
        sectionHeaderTimestampMode: SectionHeaderTimestampMode = .startOfDay
    ) -> [MessagesSection] {
        let firstLevelMessages = messages.filter { m in
            m.replyMessage == nil
        }

        let dates = Set(firstLevelMessages.map({ $0.createdAt.startOfDay() }))
            .sorted()
            .reversed()
        var result: [MessagesSection] = []

        for date in dates {
            let dayFirstLevelMessages = firstLevelMessages.filter({ $0.createdAt.isSameDay(date) })
            var dayMessages = [Message]() // insert second level in between first level
            for m in dayFirstLevelMessages {
                var replies = getRepliesFor(id: m.id, messages: messages)
                replies.sort { $0.createdAt < $1.createdAt }
                if chatType == .conversation {
                    dayMessages.append(m)
                }
                dayMessages.append(contentsOf: replies)
                if chatType == .comments {
                    dayMessages.append(m)
                }
            }

            let isFirstSection = dates.first == date
            let isLastSection = dates.last == date
            let sectionRows = wrapSectionMessages(dayMessages, chatType: chatType, replyMode: replyMode, isFirstSection: isFirstSection, isLastSection: isLastSection)
            // For "first activity" we only consider top-level messages of that day —
            // replies may have been authored on a different calendar day.
            let resolvedDate = resolveSectionDate(
                forDay: date,
                messages: dayFirstLevelMessages,
                mode: sectionHeaderTimestampMode
            )
            result.append(MessagesSection(date: resolvedDate, rows: sectionRows))
        }

        return result
    }

    /// Resolves the `Date` to expose on a `MessagesSection` based on the configured
    /// `SectionHeaderTimestampMode`. Falls back to `dayStart` when no messages are present.
    nonisolated static private func resolveSectionDate(
        forDay dayStart: Date,
        messages: [Message],
        mode: SectionHeaderTimestampMode
    ) -> Date {
        switch mode {
        case .startOfDay:
            return dayStart
        case .firstActivity:
            return messages.map(\.createdAt).min() ?? dayStart
        }
    }

    nonisolated static private func getRepliesFor(id: String, messages: [Message]) -> [Message] {
        messages.compactMap { m in
            if m.replyMessage?.id == id {
                return m
            }
            return nil
        }
    }

    nonisolated static private func wrapSectionMessages(_ messages: [Message], chatType: ChatType, replyMode: ReplyMode, isFirstSection: Bool, isLastSection: Bool) -> [MessageRow] {
        messages
            .enumerated()
            .map {
                let index = $0.offset
                let message = $0.element
                let nextMessage = chatType == .conversation ? messages[safe: index + 1] : messages[safe: index - 1]
                let prevMessage = chatType == .conversation ? messages[safe: index - 1] : messages[safe: index + 1]

                let nextMessageExists = nextMessage != nil
                let prevMessageExists = prevMessage != nil
                let nextMessageIsSameUser = nextMessage?.user.id == message.user.id
                let prevMessageIsSameUser = prevMessage?.user.id == message.user.id

                let positionInUserGroup: PositionInUserGroup
                if nextMessageExists, nextMessageIsSameUser, prevMessageIsSameUser {
                    positionInUserGroup = .middle
                } else if !nextMessageExists || !nextMessageIsSameUser, !prevMessageIsSameUser {
                    positionInUserGroup = .single
                } else if nextMessageExists, nextMessageIsSameUser {
                    positionInUserGroup = .first
                } else {
                    positionInUserGroup = .last
                }

                let positionInMessagesSection: PositionInMessagesSection
                if messages.count == 1 {
                    positionInMessagesSection = .single
                } else if !prevMessageExists {
                    positionInMessagesSection = .first
                } else if !nextMessageExists {
                    positionInMessagesSection = .last
                } else {
                    positionInMessagesSection = .middle
                }

                if replyMode == .quote {
                    return MessageRow(
                        message: $0.element, positionInUserGroup: positionInUserGroup,
                        positionInMessagesSection: positionInMessagesSection, commentsPosition: nil)
                }

                let nextMessageIsAReply = nextMessage?.replyMessage != nil
                let nextMessageIsFirstLevel = nextMessage?.replyMessage == nil
                let prevMessageIsFirstLevel = prevMessage?.replyMessage == nil

                let positionInComments: PositionInCommentsGroup
                if message.replyMessage == nil && !nextMessageIsAReply {
                    positionInComments = .singleFirstLevelPost
                } else if message.replyMessage == nil && nextMessageIsAReply {
                    positionInComments = .firstLevelPostWithComments
                } else if nextMessageIsFirstLevel {
                    positionInComments = .lastComment
                } else if prevMessageIsFirstLevel {
                    positionInComments = .firstComment
                } else {
                    positionInComments = .middleComment
                }

                let positionInSection: PositionInSection
                if !prevMessageExists, !nextMessageExists {
                    positionInSection = .single
                } else if !prevMessageExists {
                    positionInSection = .first
                } else if !nextMessageExists {
                    positionInSection = .last
                } else {
                    positionInSection = .middle
                }

                let positionInChat: PositionInChat
                if !isFirstSection, !isLastSection {
                    positionInChat = .middle
                } else if !prevMessageExists, !nextMessageExists, isFirstSection, isLastSection {
                    positionInChat = .single
                } else if !prevMessageExists, isFirstSection {
                    positionInChat = .first
                } else if !nextMessageExists, isLastSection {
                    positionInChat = .last
                } else {
                    positionInChat = .middle
                }

                let commentsPosition = CommentsPosition(
                    inCommentsGroup: positionInComments, inSection: positionInSection,
                    inChat: positionInChat)

                return MessageRow(
                    message: $0.element, positionInUserGroup: positionInUserGroup,
                    positionInMessagesSection: positionInMessagesSection,
                    commentsPosition: commentsPosition)
            }
            .reversed()
    }
}

