import UniformTypeIdentifiers

extension UTType {
    static let fits = UTType(importedAs: "fyi.seiza.fits", conformingTo: .image)
    static let xisf = UTType(importedAs: "fyi.seiza.xisf", conformingTo: .image)

    static let seizaSupportedImages: [UTType] = [
        .fits,
        .xisf,
        .jpeg,
        .png,
        .tiff,
    ]

    static let seizaAstronomyImageExtensions = SeizaCore.astronomyImageExtensions

    static let seizaSupportedImageExtensions: Set<String> = seizaAstronomyImageExtensions.union([
        "jpg", "jpeg", "jfif",
        "png",
        "tif", "tiff",
    ])
}
