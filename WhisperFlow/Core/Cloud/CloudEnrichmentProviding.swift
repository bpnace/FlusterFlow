import Foundation

protocol CloudEnrichmentProviding: TextEnriching {}

typealias CloudMetadataResolver = @Sendable (
    _ context: ContextSnapshot,
    _ sessionID: DictationSessionID
) -> CloudRequestMetadata
