//
//  StrongTextWalker.swift
//  AITranslate
//
//  Created by Luke Zhao on 12/22/24.
//

import Foundation
import Markdown

struct StrongTextWalker: MarkupWalker {
    var strongTexts: Set<String> = []
    mutating func visitStrong(_ strong: Strong) -> () {
        strongTexts.insert(strong.plainText)
    }
    mutating func visitImage(_ image: Image) -> () {
        strongTexts.insert(image.plainText)
    }
    mutating func visitHeading(_ heading: Heading) -> () {
        strongTexts.insert(heading.plainText)
    }
}

extension String {
    var markdownStrongTexts: Set<String> {
        let document = Document(parsing: self)
        var walker = StrongTextWalker()
        walker.visit(document)
        return walker.strongTexts
    }
}
