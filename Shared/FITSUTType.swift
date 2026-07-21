import UniformTypeIdentifiers

extension UTType {
    static let fits = UTType(importedAs: "fyi.seiza.fits", conformingTo: .image)

    static let seizaSupportedImages: [UTType] = [
        .fits,
        .jpeg,
        .png,
        .tiff,
    ]

    static let seizaSupportedImageExtensions: Set<String> = [
        "fits", "fit", "fts",
        "jpg", "jpeg", "jfif",
        "png",
        "tif", "tiff",
    ]
}
