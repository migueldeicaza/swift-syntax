//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftDiagnostics
import SwiftBasicFormat
import SwiftSyntax

extension FixIt {
  public init(message: FixItMessage, changes: [Changes]) {
    self.init(message: message, changes: FixIt.Changes(combining: changes))
  }

  // These overloads shouldn't be needed, but are currently required for the
  // Swift 5.5 compiler to handle non-trivial FixIt initializations using
  // leading-dot syntax.
  // TODO: These can be dropped once we require a minimum of Swift 5.6 to
  // compile the library.
  init(message: StaticParserFixIt, changes: Changes) {
    self.init(message: message as FixItMessage, changes: changes)
  }
  init(message: StaticParserFixIt, changes: [Changes]) {
    self.init(message: message as FixItMessage, changes: FixIt.Changes(combining: changes))
  }
}

extension FixIt.Changes {
  /// Replaced a present token with a missing node.
  /// If `transferTrivia` is `true`, the leading and trailing trivia of the
  /// removed node will be transferred to the trailing trivia of the previous token.
  static func makeMissing(_ token: TokenSyntax, transferTrivia: Bool = true) -> Self {
    return makeMissing([token], transferTrivia: transferTrivia)
  }

  /// Replace present tokens with missing tokens.
  /// If `transferTrivia` is `true`, the leading and trailing trivia of the
  /// removed node will be transferred to the trailing trivia of the previous token.
  static func makeMissing(_ tokens: [TokenSyntax], transferTrivia: Bool = true) -> Self {
    precondition(!tokens.isEmpty)
    precondition(tokens.allSatisfy({ $0.presence == .present }))
    var changes = tokens.map {
      FixIt.Change.replace(
        oldNode: Syntax($0),
        newNode: Syntax(TokenSyntax($0.tokenKind, leadingTrivia: [], trailingTrivia: [], presence: .missing))
      )
    }
    if transferTrivia {
      changes += FixIt.Changes.transferTriviaAtSides(from: tokens).changes
    }
    return FixIt.Changes(changes: changes)
  }

  /// If `transferTrivia` is `true`, the leading and trailing trivia of the
  /// removed node will be transferred to the trailing trivia of the previous token.
  static func makeMissing<SyntaxType: SyntaxProtocol>(_ node: SyntaxType?, transferTrivia: Bool = true) -> Self {
    guard let node = node else {
      return FixIt.Changes(changes: [])
    }
    var changes = [FixIt.Change.replace(oldNode: Syntax(node), newNode: MissingMaker().visit(Syntax(node)))]
    if transferTrivia {
      changes += FixIt.Changes.transferTriviaAtSides(from: [node]).changes
    }
    return FixIt.Changes(changes: changes)
  }

  /// Make a node present. If `leadingTrivia` or `trailingTrivia` is specified,
  /// override the default leading/trailing trivia inferred from `BasicFormat`.
  static func makePresent<T: SyntaxProtocol>(
    _ node: T,
    leadingTrivia: Trivia? = nil,
    trailingTrivia: Trivia? = nil
  ) -> Self {
    var presentNode = PresentMaker().visit(Syntax(node))
    if let leadingTrivia = leadingTrivia {
      presentNode = presentNode.with(\.leadingTrivia, leadingTrivia)
    }
    if let trailingTrivia = trailingTrivia {
      presentNode = presentNode.with(\.trailingTrivia, trailingTrivia)
    }
    if node.shouldBeInsertedAfterNextTokenTrivia,
      let nextToken = node.nextToken(viewMode: .sourceAccurate),
      leadingTrivia == nil
    {
      return [
        .replace(
          oldNode: Syntax(node),
          newNode: Syntax(presentNode).with(\.leadingTrivia, nextToken.leadingTrivia)
        ),
        .replaceLeadingTrivia(token: nextToken, newTrivia: []),
      ]
    } else if node.leadingTrivia.isEmpty,
      let previousToken = node.previousToken(viewMode: .fixedUp),
      previousToken.presence == .present,
      previousToken.trailingTrivia.isEmpty,
      BasicFormat().requiresTrailingSpace(previousToken),
      leadingTrivia == nil
    {
      /// If neither this nor the previous token are punctionation make sure they
      /// are separated by a space.
      return [
        .replace(
          oldNode: Syntax(node),
          newNode: Syntax(presentNode).with(\.leadingTrivia, .space)
        )
      ]
    } else {
      return [
        .replace(
          oldNode: Syntax(node),
          newNode: Syntax(presentNode)
        )
      ]
    }
  }

  /// Makes the `token` present, moving it in front of the previous token's trivia.
  static func makePresentBeforeTrivia(_ token: TokenSyntax) -> Self {
    if let previousToken = token.previousToken(viewMode: .sourceAccurate) {
      var presentToken = PresentMaker().visit(token)
      if !previousToken.trailingTrivia.isEmpty {
        presentToken = presentToken.with(\.trailingTrivia, previousToken.trailingTrivia)
      }
      return [
        .replaceTrailingTrivia(token: previousToken, newTrivia: []),
        .replace(oldNode: Syntax(token), newNode: Syntax(presentToken)),
      ]
    } else {
      return .makePresent(token)
    }
  }

  /// Transfers the leading and trivia trivia of `nodes` to the trailing trivia
  /// of the previous token. While doing this, it tries to be smart, merging trivia
  /// where it makes sense and refusing to add e.g. a space after punctuation,
  /// where it usually doesn't make sense.
  static func transferTriviaAtSides<SyntaxType: SyntaxProtocol>(from nodes: [SyntaxType]) -> Self {
    let removedTriviaAtSides = (nodes.first?.leadingTrivia ?? []).merging(nodes.last?.trailingTrivia ?? [])
    if !removedTriviaAtSides.isEmpty, let previousToken = nodes.first?.previousToken(viewMode: .sourceAccurate) {
      let mergedTrivia = previousToken.trailingTrivia.merging(removedTriviaAtSides)
      if previousToken.tokenKind.isPunctuation, mergedTrivia.allSatisfy({ $0.isSpaceOrTab }) {
        // Punctuation is generally not followed by spaces in Swift.
        // If this action would only add spaces to the punctuation, drop it.
        // This generally yields better results.
        return []
      }
      return [.replaceTrailingTrivia(token: previousToken, newTrivia: mergedTrivia)]
    } else {
      return []
    }
  }
}

extension TriviaPiece {
  var isSpaceOrTab: Bool {
    switch self {
    case .spaces, .tabs:
      return true
    default:
      return false
    }
  }
}
