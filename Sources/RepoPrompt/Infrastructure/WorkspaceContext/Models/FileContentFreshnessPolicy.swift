enum FileContentFreshnessPolicy {
    /// Trust the existing FileViewModel metadata/cache fast path.
    case cachedMetadata
    /// Validate disk metadata before trusting cached content; never return stale fallback on validation/load failure.
    case validateDiskMetadata
}
