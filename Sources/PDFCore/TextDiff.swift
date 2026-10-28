import Foundation

/// Différence entre deux suites (lignes, mots, pages…) par plus longue sous-suite commune.
public enum TextDiff {
    public enum Kind: Equatable { case same, added, removed }

    public struct Chunk<T> {
        public let kind: Kind
        public var items: [T]
    }

    /// Au-delà de cette taille (éléments différents × éléments différents), on ne cherche plus
    /// l'alignement fin : tout le bloc central est marqué supprimé puis ajouté.
    static let maxCells = 4_000_000

    public static func diff<T: Equatable>(_ a: [T], _ b: [T]) -> [Chunk<T>] {
        diff(a, b, equal: { $0 == $1 })
    }

    /// `equal(x, y)` est toujours appelé avec x pris dans `a` et y pris dans `b`.
    public static func diff<T>(_ a: [T], _ b: [T], equal: (T, T) -> Bool) -> [Chunk<T>] {
        var chunks: [Chunk<T>] = []
        func push(_ kind: Kind, _ item: T) {
            if let last = chunks.last, last.kind == kind {
                chunks[chunks.count - 1].items.append(item)
            } else {
                chunks.append(Chunk(kind: kind, items: [item]))
            }
        }

        // Début et fin communs : pas besoin de les aligner.
        var p = 0
        while p < a.count && p < b.count && equal(a[p], b[p]) { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && equal(a[a.count - 1 - s], b[b.count - 1 - s]) { s += 1 }

        for k in 0..<p { push(.same, a[k]) }
        let A = Array(a[p..<(a.count - s)])
        let B = Array(b[p..<(b.count - s)])
        let n = A.count, m = B.count

        if n > 0 || m > 0 {
            if n * m > maxCells {
                for x in A { push(.removed, x) }
                for y in B { push(.added, y) }
            } else {
                // L[i][j] = longueur de la plus longue sous-suite commune de A[i...] et B[j...]
                let w = m + 1
                var L = [Int32](repeating: 0, count: (n + 1) * w)
                if n > 0 && m > 0 {
                    for i in stride(from: n - 1, through: 0, by: -1) {
                        for j in stride(from: m - 1, through: 0, by: -1) {
                            L[i * w + j] = equal(A[i], B[j])
                                ? L[(i + 1) * w + j + 1] + 1
                                : max(L[(i + 1) * w + j], L[i * w + j + 1])
                        }
                    }
                }
                var i = 0, j = 0
                while i < n || j < m {
                    if i < n && j < m && equal(A[i], B[j]) {
                        push(.same, A[i]); i += 1; j += 1
                    } else if i < n && (j == m || L[(i + 1) * w + j] >= L[i * w + j + 1]) {
                        push(.removed, A[i]); i += 1
                    } else {
                        push(.added, B[j]); j += 1
                    }
                }
            }
        }

        for k in (a.count - s)..<a.count { push(.same, a[k]) }
        return chunks
    }
}
