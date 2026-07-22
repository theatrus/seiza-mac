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

    static let seizaSupportedImageExtensions: Set<String> = [
        "fits", "fit", "fts",
        "xisf",
        "jpg", "jpeg", "jfif",
        "png",
        "tif", "tiff",
    ]
}
