//
//  VideoPicker.swift
//  Anime4KTool
//
//  把「相册里选中的视频」复制到 App 沙盒临时目录，供后续处理使用。
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// PhotosPicker 选中的视频：`loadTransferable` 时把文件复制到临时目录并返回 URL。
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileManager = FileManager.default
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let target = fileManager.temporaryDirectory
                .appendingPathComponent("anime4k_input_\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: received.file, to: target)
            return ImportedMovie(url: target)
        }
    }
}
