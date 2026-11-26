// ═══════════════════════════════════════════════════════════════════════════
//  Icône opaque pour TestFlight (testflight.yml).
//
//  App Store Connect refuse une icône transparente ou avec une couche alpha
//  (ITMS-90717). assets/icon.png en a une (coins et halo) : chaque image est
//  posée sur un fond noir opaque et enregistrée en PNG sans alpha. iOS affiche
//  déjà les zones transparentes d'une icône sur du noir (voir l'aperçu
//  « Default » de assets/icons/make_icons.py) : le rendu ne change pas.
//
//  Usage : flatten_icon entrée.png sortie.png [entrée.png sortie.png …]
// ═══════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FlattenError: Error, CustomStringConvertible {
    let description: String
}

func flatten(_ input: String, to output: String) throws {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw FlattenError(description: "image illisible : \(input)")
    }
    // Espace de couleur de l'image s'il est en RVB (pas de conversion), sinon sRGB.
    let width = image.width, height = image.height
    let spaces = [image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil },
                  CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
    guard let context = spaces.lazy.compactMap({
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: $0, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }).first else {
        throw FlattenError(description: "contexte impossible : \(input)")
    }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(rect)
    context.draw(image, in: rect)
    guard let opaque = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else {
        throw FlattenError(description: "écriture impossible : \(output)")
    }
    CGImageDestinationAddImage(destination, opaque, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FlattenError(description: "écriture ratée : \(output)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty, arguments.count % 2 == 0 else {
    FileHandle.standardError.write(Data("usage : flatten_icon entrée.png sortie.png [entrée.png sortie.png …]\n".utf8))
    exit(2)
}
do {
    for index in stride(from: 0, to: arguments.count, by: 2) {
        try flatten(arguments[index], to: arguments[index + 1])
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
