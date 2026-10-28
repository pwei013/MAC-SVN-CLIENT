import Darwin
import Foundation

@main
enum ChecksMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--filter" && !arguments[1].isEmpty) else {
            print("Usage: SVNCoreChecks [--filter name-substring]")
            exit(2)
        }
        let filter = arguments.count == 2 ? arguments[1] : nil
        let integration = SVNClientIntegrationTests()
        let xml = SVNXMLTests()
        let processes = ProcessRunnerTests()
        let credentials = RepositoryCredentialTests()
        let listings = RepositoryListingTests()
        let checkoutProgress = CheckoutProgressTests()
        let recentLocations = RecentLocationTests()
        let repositorySearch = RepositorySearchTests()
        let globalIgnores = GlobalIgnoreTests()
        let nativeUnignore = NativeUnignoreTests()
        let ignoreConfigEdit = IgnoreConfigEditTests()
        let nodeKinds = WorkingCopyNodeKindTests()
        let directoryIgnores = DirectoryIgnoreTests()
        let ignoreScopes = IgnoreScopeTests()
        let remoteDiff = RemoteDiffTests()
        let fileComparison = FileComparisonTests()
        let lineComparison = LineComparisonTests()
        let projectState = ProjectStateTests()
        let history = HistoryTests()
        let incoming = IncomingUpdatesTests()
        let decoration = ComparisonDecorationTests()
        let operationProgress = OperationProgressTests()
        let automaticCommit = AutomaticCommitTests()
        let commitReview = CommitReviewTests()
        let workingFilters = WorkingCopyFilterTests()
        let localActions = LocalActionTests()
        let recovery = CommitRecoveryTests()
        let conflicts = ConflictResolutionTests()
        let checks: [(name: String, run: () async throws -> Void)] = [
            ("conflict-resolution-mine-backups-preserve", { try await conflicts.testMineResolutionIsReviewedLocalAndPreservesBackupsAndOtherFiles() }),
            ("conflict-resolution-theirs-pinned-version", { try await conflicts.testTheirsUsesPinnedConflictVersionEvenWhenHeadAdvances() }),
            ("conflict-resolution-manual-markers-eols", { try await conflicts.testManualMergeRejectsMarkersAndWritesExplicitLineEndings() }),
            ("conflict-resolution-manual-encoding", { try await conflicts.testManualMergePreservesUTF16BOMAndLegacyEncodingLosslessly() }),
            ("conflict-resolution-binary-mislabeled-code", { try await conflicts.testBinaryChoicesKeepRawBytesAndMislabeledCodeRemainsComparable() }),
            ("conflict-resolution-merge-incoming-branch", { try await conflicts.testMergeConflictUsesIncomingBranchSnapshotRatherThanWorkingBranchHead() }),
            ("conflict-resolution-snapshot-drift", { try await conflicts.testWorkingAuxiliaryAndRepositoryIdentityDriftStopBeforeWriting() }),
            ("conflict-resolution-property-tree-blocked", { try await conflicts.testPropertyTreeAndCompositeConflictsAreNeverSilentlyResolved() }),
            ("conflict-resolution-boundaries-cancel", { try await conflicts.testPathBoundariesSymbolicLinksBackupScopeAndCancellationDoNotWrite() }),
            ("conflict-resolution-failure-no-replay", { try await conflicts.testResolveFailureIsNotReplayedAndLeavesRecoverableBackup() }),
            ("conflict-resolution-special-names-size-limits", { try await conflicts.testSpecialNamedFilesAndSizeLimitsStayBounded() }),
            ("commit-recovery-outdated-update-no-replay", { try await recovery.testOutOfDateRecommendsUpdateAndDoesNotRetryCommit() }),
            ("commit-recovery-parent-selection-revalidation", { try await recovery.testMissingParentsUsesTypedPathsAndOnlyChangesSelection() }),
            ("commit-recovery-path-unadd-no-guess", { try await recovery.testMissingPathDoesNotGuessTargetsAndCanUnaddConfirmedFile() }),
            ("commit-recovery-uncertain-confirmed-readonly", { try await recovery.testUncertainAndConfirmedResultsRecommendReadOnlyChecks() }),
            ("commit-recovery-cleanup-ack-preserve", { try await recovery.testCleanupRequiresAcknowledgmentAndNeverRemovesFiles() }),
            ("commit-recovery-drift-fallback-cancel", { try await recovery.testIdentityDriftFallbackAndCancellationPreventRepairs() }),
            ("commit-recovery-account-scope-diagnostics", { try await recovery.testAccountSuggestionUsesRepositoryScopeAndPreservesDiagnostics() }),
            ("local-action-undo-add-special-preserve", { try await localActions.testUndoAddKeepsSpecialNamedFilesAndUnrelatedChanges() }),
            ("local-action-undo-directory-retain-extra", { try await localActions.testUndoAddedDirectoryIsRecursiveAndKeepsExtraFiles() }),
            ("local-action-undo-reject-history", { try await localActions.testUndoAddRejectsCommittedCopiedAndMovedItems() }),
            ("local-action-delete-keep-local-commit", { try await localActions.testDeleteKeepsModifiedAndUntrackedFilesUntilAndAfterCommit() }),
            ("local-action-delete-protect-edits", { try await localActions.testDeleteCanRemoveCleanFilesButNeverForcesLocalChanges() }),
            ("local-action-drift-boundaries-cancel", { try await localActions.testRevalidationBoundariesAndCancellationPreventWrites() }),
            ("local-action-failure-no-replay", { try await localActions.testFailedLocalWriteIsNotReplayed() }),
            ("local-action-commit-error-categories", { try localActions.testCommitFailureCategoriesPreserveSpecificDiagnostics() }),
            ("local-action-commit-real-rejections", { try await localActions.testRealOutOfDateAndHookRejectionsAreSpecificAndKeepChanges() }),
            ("local-action-commit-invalid-files-parents", { try await localActions.testInvalidCommitListsFilesAndMissingAddedParentsBeforeSending() }),
            ("local-action-commit-post-confirmation-warning", { try await localActions.testConfirmedRevisionWithPostCommitWarningIsNotReportedAsRejected() }),
            ("checkout-overlay-overwrite-preserve-progress", { try await checkoutProgress.testOverlayOverwritesSameNamesAndKeepsAllOtherFiles() }),
            ("checkout-overlay-type-symlink-conflicts", { try await checkoutProgress.testOverlayRejectsTypeClashesAndSymlinksBeforeWriting() }),
            ("checkout-overlay-existing-working-copies", { try await checkoutProgress.testOverlayUpdatesMatchingWorkingCopyButRejectsNestedForeignScope() }),
            ("checkout-update-preserve-edits-extras-scope", { try await checkoutProgress.testMatchingWorkingCopyUpdatesAndPreservesEditsExtrasAndScope() }),
            ("checkout-update-postpone-conflicts-retain-extras", { try await checkoutProgress.testMatchingWorkingCopyPostponesConflictsAndRetainsFilesInDeletedDirectories() }),
            ("checkout-update-identity-path-revalidation", { try await checkoutProgress.testWorkingCopyRejectsDifferentPathRepositoryAndChangedIdentityBeforeWriting() }),
            ("checkout-overlay-concurrent-failure-no-replay", { try await checkoutProgress.testOverlayRechecksFilesAndDoesNotReplayFailedWrites() }),
            ("checkout-overlay-cancel-before-write", { try await checkoutProgress.testOverlayCancellationBeforeCheckoutLeavesDirectoryUntouched() }),
            ("checkout-overlay-explicit-file-batches", { try await checkoutProgress.testOverlayBatchesExplicitFilesWithoutTouchingExtras() }),
            ("checkout-overlay-safe-manifest", { try checkoutProgress.testCheckoutManifestRejectsUnsafeAndDuplicatePaths() }),
            ("working-filter-select-all-visible-eligible", { try workingFilters.testSelectAllUsesVisibleEligibleRowsAndPreservesHiddenChecks() }),
            ("automatic-commit-mixed-ignored-unselected", { try await automaticCommit.testMixedSelectionAddsNewTreesAndPreservesEverythingElse() }),
            ("commit-review-readonly-expansion-counts", { try await commitReview.testReadOnlyExpansionMatchesCommittedFilesAndCounts() }),
            ("commit-review-config-inherited-ignore-scope", { try await commitReview.testUserConfigAndInheritedPropertiesExcludeOnlyApplicableNames() }),
            ("commit-review-leaf-empty-symlink", { try await commitReview.testLeafParentsEmptyDirectoryAndSymlinkAreListedWithoutFollowingLinks() }),
            ("commit-review-change-reload", { try await commitReview.testChangedManifestStopsBeforeAddAndCanBeReloaded() }),
            ("commit-review-ignore-change-nested-boundary", { try await commitReview.testChangedIgnoreRulesAndNestedWorkingCopyNeverCommitUnreviewedFiles() }),
            ("commit-review-deleted-cancel-readonly", { try await commitReview.testDeletedFilesCountAndCancellationRemainReadOnly() }),
            ("commit-review-file-arriving-during-add", { try await commitReview.testFileArrivingDuringAddStopsBeforeRemoteCommit() }),
            ("commit-review-large-folder-batched-reads", { try await commitReview.testLargeFolderUsesBatchedSVNReads() }),
            ("automatic-commit-only-required-new-parents", { try await automaticCommit.testOnlyRequiredParentsAreIncludedForAnExplicitNewFile() }),
            ("automatic-commit-existing-added-parent", { try await automaticCommit.testAlreadyAddedParentsDoNotPullInUnselectedAddedSiblings() }),
            ("automatic-commit-preflight-ignored-missing", { try await automaticCommit.testIgnoredAndMissingSelectionsStopBeforeAnyAddOrCommit() }),
            ("automatic-commit-partial-add-no-replay", { try await automaticCommit.testPartialAddFailureIsNotReplayedAndNeverStartsCommit() }),
            ("automatic-commit-rejection-preserves-add", { try await automaticCommit.testRejectedCommitKeepsAddAndReportsTheExpandedScope() }),
            ("automatic-commit-cancel-symlink-boundary", { try await automaticCommit.testCancellationAndSymlinkParentDoNotWrite() }),
            ("automatic-commit-native-inherited-ignores", { try await automaticCommit.testInheritedNativeIgnoresApplyInsideNewParentsAndTrees() }),
            ("automatic-commit-nested-working-copy", { try await automaticCommit.testNestedWorkingCopyIsNeverSweptIntoTheNewTree() }),
            ("working-filter-commit-block-reasons", { try workingFilters.testCommitBlockReasonsCoverMixedHiddenSelectionsAndConflicts() }),
            ("working-filter-status-conflicts-properties", { try workingFilters.testStatusGroupsPrioritizeAllConflictKindsAndProperties() }),
            ("working-filter-query-kind-status-selection", { try workingFilters.testPathTypeAndStatusComposeWithoutChangingInput() }),
            ("working-filter-node-kind-metadata", { try workingFilters.testNodeKindsUseMetadataInsteadOfExtensions() }),
            ("working-filter-legacy-draft-roundtrip", { try workingFilters.testLegacyProjectDraftsKeepContentWhenFiltersAreMissing() }),
            ("working-filter-large-cancellation", { try await workingFilters.testLargeFilteringAndCancellationStayBounded() }),
            ("operation-progress-update-authors-local-batch", { try await operationProgress.testUpdateStreamsFilesAndReadsLocalAuthorsInBatches() }),
            ("operation-progress-commit-explicit-files", { try await operationProgress.testCommitStreamsExplicitFilesAndPreservesUnselectedChanges() }),
            ("operation-progress-live-utf8-password", { try await operationProgress.testLiveCommitHandlesSplitUTF8AndRedactsPassword() }),
            ("operation-progress-failure-no-replay", { try await operationProgress.testFailedOrUnconfirmedCommitIsNotReplayed() }),
            ("operation-progress-cancel-reap", { try await operationProgress.testUpdateCancellationReapsChildAndDoesNotReportCompletion() }),
            ("operation-progress-output-bound-metadata-warning", { try await operationProgress.testLargeOutputIsBoundedAndMetadataFailureKeepsUpdateSuccess() }),
            ("phase1-project-state-roundtrip-isolation", { try await projectState.testRoundTripIsolatesCheckoutScopeAndSwitchedURL() }),
            ("phase1-project-state-sequence-cancel", { try await projectState.testMonotonicSavesAndCancellationDoNotOverwriteNewerDraft() }),
            ("phase1-project-state-corrupt-oversize", { try await projectState.testCorruptionAndOversizeFallBackWithoutTruncatingExistingDraft() }),
            ("phase1-project-state-retention", { try await projectState.testRetentionKeepsRecentProjectsAndUnrelatedFiles() }),
            ("phase1-project-state-permissions-symlink", { try await projectState.testPrivatePermissionsAndSymlinkProtection() }),
            ("phase1-project-state-large-selection", { try await projectState.testLargeSelectionAndSerializedRecordBudget() }),
            ("phase1-project-state-identity-validation", { try projectState.testIdentityRejectsCredentialsAndForeignRepositoryMapping() }),
            ("phase1-history-snapshot-pages-readonly", { try await history.testHistoryPagesKeepSnapshotAndMetadataReadOnly() }),
            ("phase1-history-copies-encoding-comparison", { try await history.testHistoryComparisonTracksCopiesAndMislabeledTextWithoutWorkingCopy() }),
            ("phase1-history-bounds-cancel", { try await history.testHistoryRejectsMalformedAndBoundedResponsesAndCancels() }),
            ("phase1-incoming-readonly-overlap", { try await incoming.testIncomingUpdatesReportsRemoteChangesAndPreservesLocalState() }),
            ("phase1-incoming-validation-bounds", { try await incoming.testIncomingUpdatesRejectsInvalidScopesMalformedAndOversizeResponses() }),
            ("phase1-incoming-cancel-auth", { try await incoming.testIncomingUpdatesCanCancelAndKeepsAuthenticationErrors() }),
            ("phase1-incoming-replaced-path-snapshot", { try await incoming.testIncomingComparisonUsesCheckedPathForReplacedNodes() }),
            ("phase1-history-switched-path-scope", { try await history.testWorkingHistoryResolvesSwitchedNodesAndRejectsUntrackedScopes() }),
            ("phase1-diff-characters-unicode", { try decoration.testCharacterChangesKeepUnicodeRangesAndSeparateEdits() }),
            ("phase1-diff-collapsed-context", { try decoration.testCollapsedContextMapsOriginalRowsWithoutDuplicates() }),
            ("phase1-diff-visible-syntax", { try decoration.testVisibleCodeStylingUsesBoundedLiteralTokens() }),
            ("phase1-diff-long-lines-budget", { try decoration.testCharacterBudgetAndVeryLongLinesRemainBounded() }),
            ("phase1-diff-decoration-cancel", { try await decoration.testDecorationAndContextCancellation() }),
            ("browse-checkout-selective-commit-update", {
                try await integration.testBrowseCheckoutSelectiveCommitDirectoryCommitAndUpdate()
            }),
            ("commit-failure-no-replay-password-protection", {
                try await integration.testCommitFailureIsNotAutomaticallyReplayed()
            }),
            ("added-directory-selected-children", {
                try await integration.testAddedDirectoryCommitsOnlySelectedChildren()
            }),
            ("missing-file-schedule-delete-commit", {
                try await integration.testMissingFileCanBeScheduledAndCommittedAsDeletion()
            }),
            ("checkout-nonempty-destination", {
                try await integration.testCheckoutRejectsNonemptyDestinationWithoutChangingItsContents()
            }),
            ("xml-list-names-metadata", {
                try xml.testListDecodesNamesAndOptionalCommitMetadata()
            }),
            ("xml-info-working-copy-root", {
                try xml.testInfoRequiresALocalWorkingCopyRoot()
            }),
            ("xml-status-properties-conflicts", {
                try xml.testStatusKeepsPropertyChangesAndRejectsConflictsForCommit()
            }),
            ("xml-malformed-response", {
                try xml.testMalformedOrUnexpectedXMLIsRejected()
            }),
            ("repository-location-validation", {
                try xml.testRepositoryLocationRejectsEmbeddedCredentialsAndNonRepositoryParts()
            }),
            ("credential-scope-canonical-origin", {
                try credentials.testScopeCanonicalizesOriginAndRepositoryRoot()
            }),
            ("credential-scope-segment-boundaries", {
                try credentials.testScopeRejectsDotPathSegmentsAndMatchesSegmentBoundaries()
            }),
            ("credential-cache-repository-isolation", {
                try credentials.testCredentialsStayWithinTheRepositoryOriginAndPath()
            }),
            ("credential-cache-new-session", {
                try credentials.testNewCacheLoadsSavedCredentialsForRepositoryChildren()
            }),
            ("credential-cache-save-failure-session", {
                try credentials.testFailedPersistenceKeepsOnlySessionCredentials()
            }),
            ("credential-cache-most-specific-root", {
                try credentials.testMostSpecificRepositoryRootWinsInBothSessionAndStorage()
            }),
            ("credential-authentication-error-classification", {
                try credentials.testOnlyAuthenticationErrorsRequestCredentialsAgain()
            }),
            ("credential-authentication-redacted-password", {
                try await credentials.testAuthenticationClassificationSurvivesPasswordRedaction()
            }),
            ("xml-repository-identity", {
                try credentials.testRepositoryInfoUsesServerRootAndUUIDWithoutWorkingCopyFields()
            }),
            ("listing-default-natural-name-folder-first", {
                try listings.testDefaultSortUsesNaturalNamesAndKeepsDirectoriesFirst()
            }),
            ("listing-sort-numeric-revisions", {
                try listings.testRevisionSortUsesNumbersInBothDirections()
            }),
            ("listing-sort-authors-name-ties", {
                try listings.testAuthorSortSupportsBothDirectionsAndNaturalNameTies()
            }),
            ("listing-sort-sizes", {
                try listings.testSizeSortSupportsBothDirections()
            }),
            ("listing-sort-last-commit-times", {
                try listings.testLastCommitTimeSortSupportsBothDirectionsAndMissingDates()
            }),
            ("listing-date-fractional-seconds-missing", {
                try listings.testCommitDatesPreserveRawValueAndParseOptionalFractionalSeconds()
            }),
            ("listing-sort-multiple-columns-deterministic", {
                try listings.testMultipleSortColumnsAndEmptySortHaveDeterministicNameFallback()
            }),
            ("listing-cache-ttl-empty-directory", {
                try listings.testCacheExpiresAtTTLWithoutExtendingLifetimeOnReads()
            }),
            ("listing-cache-lru-reads", {
                try listings.testCacheEvictsLeastRecentlyReadListing()
            }),
            ("listing-cache-replacement", {
                try listings.testCacheReplacementRefreshesContentsTTLAndRecency()
            }),
            ("listing-cache-canonical-url-isolation-clear", {
                try listings.testCacheUsesCompleteCanonicalURLKeysAndCanBeCleared()
            }),
            ("process-large-stdout-stderr", {
                try await processes.testCapturesLargeStdoutAndStderrWithoutBlocking()
            }),
            ("process-live-stdout-ordered-byte-handshake", {
                try await checkoutProgress.testStdoutCallbackRunsBeforeExitAndRetainsOrderedBytes()
            }),
            ("checkout-live-utf8-tail-count-password", {
                try await checkoutProgress.testCheckoutStreamsWholeUTF8LinesCountsUniqueItemsAndRedactsPassword()
            }),
            ("checkout-progress-real-pinned-revision", {
                try await checkoutProgress.testRealCheckoutUsesCountedRevisionDespiteNewRemoteCommit()
            }),
            ("checkout-progress-failure-no-complete-replay", {
                try await checkoutProgress.testCheckoutFailureNeverCompletesOrReplays()
            }),
            ("checkout-progress-nonempty-before-command", {
                try await checkoutProgress.testCheckoutRejectsNonemptyDestinationBeforeAnyCommand()
            }),
            ("checkout-progress-destination-rechecked", {
                try await checkoutProgress.testCheckoutRechecksDestinationAfterCounting()
            }),
            ("checkout-progress-cancel-process-no-completion", {
                try await checkoutProgress.testCheckoutCancellationStopsProcessWithoutCompletionOrReplay()
            }),
            ("location-display-chinese-emoji-ascii-preserved", {
                try recentLocations.testDisplayDecodesChineseAndEmojiWithoutChangingASCIISpelling()
            }),
            ("location-display-invalid-utf8-escapes", {
                try recentLocations.testDisplayKeepsMalformedAndInvalidUTF8Escapes()
            }),
            ("location-display-canonical-round-trip", {
                try recentLocations.testDisplayRoundTripsThroughRepositoryCanonicalization()
            }),
            ("history-deduplicate-recent-limit", {
                try recentLocations.testHistoryDeduplicatesAndKeepsOnlyLimitedRecentItems()
            }),
            ("history-remove-pinned-recent-persistence", {
                try recentLocations.testRemovingRecentAndPinnedItemsPersistsWithoutChangingOtherHistory()
            }),
            ("history-pin-order-survives-visits", {
                try recentLocations.testPinnedOrderSurvivesVisitsAndNewPinsGoFirst()
            }),
            ("history-pin-eviction-unpin-most-recent", {
                try recentLocations.testPinnedItemsSurviveRecentEvictionAndUnpinBecomesMostRecent()
            }),
            ("history-clear-keeps-deduplicated-pins", {
                try recentLocations.testHistoryDeduplicatesPinnedAndClearPreservesThem()
            }),
            ("history-legacy-preferences-pinned-round-trip", {
                try recentLocations.testLegacyPreferencesLoadAndPinnedPreferencesRoundTrip()
            }),
            ("search-real-recursive-paths-metadata", {
                try await repositorySearch.testRealRecursiveSearchKeepsDistinctPathsAndMetadata()
            }),
            ("search-xml-full-path-metadata-server-order", {
                try repositorySearch.testSearchParserFiltersFullPathsAndPreservesMetadataWithoutSorting()
            }),
            ("search-xml-bounded-results-total-count", {
                try repositorySearch.testSearchParserBoundsResultsButCountsAllMatches()
            }),
            ("search-directories-only-before-limit", {
                try repositorySearch.testDirectoriesOnlyFiltersBeforeLimitAndCountsOnlyFolders()
            }),
            ("search-xml-malformed-blank-query", {
                try repositorySearch.testSearchRejectsMalformedXMLAndBlankQueries()
            }),
            ("search-blank-query-no-command", {
                try await repositorySearch.testBlankClientSearchDoesNotLaunchAnyCommand()
            }),
            ("search-single-list-authentication-redaction", {
                try await repositorySearch.testClientSearchUsesOneAuthenticatedRecursiveListAndRedactsErrors()
            }),
            ("search-cancel-recursive-list", {
                try await repositorySearch.testCancellingSearchTerminatesTheRecursiveList()
            }),
            ("search-cancel-xml-parser", {
                try await repositorySearch.testSearchParsingHonoursTaskCancellation()
            }),
            ("search-child-url-literal-segments-boundaries", {
                try repositorySearch.testRecursiveChildURLPreservesLiteralSegmentsAndRejectsEscapePaths()
            }),
            ("ignore-parse-validation-deduplication", {
                try globalIgnores.testRulesParseDeduplicateAndRejectUnsafeValues()
            }),
            ("ignore-context-suggestions-literal-name-kind", {
                try globalIgnores.testContextSuggestionsRespectNodeTypeAndEscapeLiteralNames()
            }),
            ("ignore-context-native-globs-unicode-whitespace-add", {
                try await globalIgnores.testContextPatternsMatchNativeSVNWithoutExpandingLiteralGlobNames()
            }),
            ("ignore-show-opt-in-native-sources-bounded-directory", {
                try await globalIgnores.testShowIgnoredIsOptInAndKeepsIgnoredDirectoriesBounded()
            }),
            ("ignore-unignore-overlapping-rules-native-preflight", {
                try await globalIgnores.testUnignorePlanFindsAllMatchingRulesWithoutChangingFilesOrConfiguration()
            }),
            ("ignore-unignore-native-rules-stale-paths-no-write", {
                try await globalIgnores.testUnignorePlanRejectsNativeRulesStaleRowsAndEscapingPathsWithoutWrites()
            }),
            ("ignore-config-edit-interpolation-permissions-backup", {
                try ignoreConfigEdit.testConfigEditPreservesUnrelatedTextInterpolationAndPermissionsWithRestrictedBackup()
            }),
            ("ignore-config-edit-system-default-user-override", {
                try ignoreConfigEdit.testConfigEditOverridesSystemAndCompiledDefaultsOnlyInUserFile()
            }),
            ("ignore-config-edit-default-empty-interpolation", {
                try ignoreConfigEdit.testConfigEditHandlesDefaultFallbackEmptyAndUnsafeInterpolationWithoutWriting()
            }),
            ("ignore-config-edit-drift-symlink-no-write", {
                try ignoreConfigEdit.testConfigEditRefusesDriftAndSymlinksBeforeWriting()
            }),
            ("ignore-config-edit-real-svn-unicode-literal", {
                try await ignoreConfigEdit.testConfigEditNativeSVNReadbackPreservesOtherIgnoresAndUnicodeLiteralWhitespace()
            }),
            ("ignore-settings-effective-user-system-defaults-empty", {
                try ignoreConfigEdit.testConfigSettingsLoadsUserSystemDefaultsAndExplicitEmptySources()
            }),
            ("ignore-settings-save-clear-bytes-drift-injection", {
                try ignoreConfigEdit.testConfigSettingsSavePreservesBytesClearsExplicitlyAndRejectsDriftOrInjection()
            }),
            ("ignore-settings-real-svn-save-explicit-clear", {
                try await ignoreConfigEdit.testConfigSettingsNativeSaveAndExplicitClearReadback()
            }),
            ("ignore-native-unignore-combined-sources-ancestor-scope", {
                try await nativeUnignore.testCombinedSourcesAndAncestorOutsideOpenedScopePreserveOtherRules()
            }),
            ("ignore-native-unignore-property-spaces-scope-empty", {
                try await nativeUnignore.testPropertyWhitespaceIsLiteralAndParentIgnoreIsNotInherited()
            }),
            ("ignore-native-unignore-drift-no-write", {
                try await nativeUnignore.testConfigOrPropertyDriftStopsBeforeNativeWrites()
            }),
            ("ignore-native-unignore-failure-no-replay-backups", {
                try await nativeUnignore.testFailedPropertyWriteIsNotReplayedAndKeepsBackups()
            }),
            ("ignore-native-unignore-unchecked-out-inherited-source", {
                try await nativeUnignore.testUnignoreRemoteInheritedSourceRequiresCheckoutAndDoesNotCommit()
            }),
            ("ignore-native-properties-xml-whitelist-base64", {
                try nativeUnignore.testIgnorePropertyXMLWhitelistsAndDecodesNativeValues()
            }),
            ("working-copy-node-kinds-real-missing-deleted-links", {
                try await nodeKinds.testRealNodeKindsIncludeLinksAndMissingOrDeletedDirectories()
            }),
            ("working-copy-node-kinds-one-safe-batch-failure-fallback", {
                try await nodeKinds.testMissingNodeMetadataUsesOneSafeBatchAndFailureDoesNotLoseStatus()
            }),
            ("directory-ignore-read-local-inherited-scope", {
                try await directoryIgnores.testDirectoryIgnoreSettingsReadsLocalAndInheritedScope()
            }),
            ("directory-ignore-save-spaces-clear-local-only", {
                try await directoryIgnores.testDirectoryIgnoreSavePreservesSpacesAndClearsOnlyLocalProperties()
            }),
            ("directory-ignore-drift-controls-before-write", {
                try await directoryIgnores.testDirectoryIgnoreSaveRejectsDriftAndInvalidControlsBeforeWriting()
            }),
            ("directory-ignore-unsafe-targets-added-directories", {
                try await directoryIgnores.testDirectoryIgnoreSettingsRejectsUnsafeTargetsAndSupportsAddedDirectories()
            }),
            ("directory-ignore-failure-no-replay-backups", {
                try await directoryIgnores.testDirectoryIgnoreSaveFailureIsNotReplayedAndReportsBackups()
            }),
            ("ignore-scope-suggestions-literals-whitespace", {
                try ignoreScopes.testScopeSuggestionsPreserveLiteralNamesAndSeparateGlobalWhitespace()
            }),
            ("ignore-scope-native-direct-parent-recursive", {
                try await ignoreScopes.testDirectoryScopesAppendToDirectParentAndRespectNativeScope()
            }),
            ("ignore-scope-invalid-stale-targets-no-write", {
                try await ignoreScopes.testDirectoryScopesRejectInvalidTargetsBeforeWriting()
            }),
            ("remote-diff-head-working-copy-unchanged", {
                try await remoteDiff.testRemoteDiffUsesHeadAndLeavesWorkingCopyUnchanged()
            }),
            ("remote-diff-literal-paths-binary-missing-head", {
                try await remoteDiff.testRemoteDiffHandlesLiteralPathsBinaryAndMissingHead()
            }),
            ("remote-diff-invalid-stale-no-server-read", {
                try await remoteDiff.testRemoteDiffRejectsInvalidAndStaleTargetsBeforeRemoteRead()
            }),
            ("remote-diff-auth-cancel-bounded-output", {
                try await remoteDiff.testRemoteDiffAuthenticationCancellationAndBoundedOutput()
            }),
            ("file-comparison-mislabeled-text-pinned-head-base", {
                try await fileComparison.testFileComparisonReadsMislabeledTextAtPinnedHeadAndBaseReadOnly()
            }),
            ("file-comparison-unicode-chinese-binary", {
                try await fileComparison.testFileComparisonDecodesUnicodeAndChineseButRejectsBinary()
            }),
            ("file-comparison-literal-missing-size-limits", {
                try await fileComparison.testFileComparisonHandlesLiteralPathsMissingHeadAndSizeLimits()
            }),
            ("file-comparison-auth-cancel-stale-mapping", {
                try await fileComparison.testFileComparisonAuthenticationCancellationAndStaleMapping()
            }),
            ("line-comparison-align-classify-numbers", {
                try lineComparison.testAlignmentPreservesNumbersAndClassifiesChanges()
            }),
            ("line-comparison-repeat-unicode-whitespace-final-newline", {
                try lineComparison.testRepeatedLinesUnicodeWhitespaceAndFinalNewline()
            }),
            ("line-comparison-identical-empty", {
                try lineComparison.testIdenticalAndEmptyFiles()
            }),
            ("line-comparison-large-bounded-deterministic", {
                try lineComparison.testLargeUnanchoredChangesRemainBoundedAndDeterministic()
            }),
            ("line-comparison-limit-cancel", {
                try await lineComparison.testLineLimitAndCancellation()
            }),
            ("ignore-config-precedence-continuations-empty", {
                try globalIgnores.testConfigurationMergesPrecedenceContinuationsDefaultsAndExplicitEmpty()
            }),
            ("ignore-config-defaults-unsafe-preserved", {
                try globalIgnores.testMissingConfigUsesDefaultsButUnsafeConfigFailsWithoutOverride()
            }),
            ("ignore-arguments-status-add-literal-scope", {
                try await globalIgnores.testOnlyStatusAndAddReceiveOneLiteralConfigArgument()
            }),
            ("ignore-real-status-recursive-add-tracked-config", {
                try await globalIgnores.testRealStatusAndRecursiveAddPreserveTrackedChangesAndExistingIgnores()
            }),
            ("ignore-add-explicit-target-ancestor-no-write", {
                try await globalIgnores.testAddRejectsIgnoredExplicitTargetsAndAncestorsBeforeWriting()
            }),
            ("process-cancellation-and-exit", {
                try await processes.testCancellationTerminatesStartedSleepAndThrowsCancellationError()
            })
        ]

        let selected = filter.map { keyword in checks.filter { $0.name.contains(keyword) } } ?? checks
        guard !selected.isEmpty else { print("No checks matched the filter"); exit(2) }
        var failures = 0
        for check in selected {
            do {
                try await check.run()
                print("PASS \(check.name)")
            } catch {
                failures += 1
                print("FAIL \(check.name): \(error.localizedDescription)")
            }
        }
        print("\(selected.count - failures)/\(selected.count) checks passed")
        if failures > 0 { exit(1) }
    }
}

enum CheckFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): return message
        }
    }
}

func expect(_ condition: @autoclosure () throws -> Bool,
            _ message: String = "Condition was not satisfied",
            file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else {
        throw CheckFailure.failed("\(file):\(line): \(message)")
    }
}

func require<T>(_ value: T?, _ message: String = "Required value was absent",
                file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        throw CheckFailure.failed("\(file):\(line): \(message)")
    }
    return value
}

func expectThrows<E: Error, Value>(_ errorType: E.Type,
                                  _ message: String = "Expected operation to throw",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  operation: () throws -> Value) throws {
    do {
        _ = try operation()
    } catch is E {
        return
    } catch {
        throw CheckFailure.failed("\(file):\(line): Unexpected error type \(String(describing: type(of: error)))")
    }
    throw CheckFailure.failed("\(file):\(line): \(message)")
}

func withCheckTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw CheckFailure.failed("Process check exceeded its time limit")
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw CheckFailure.failed("Process check did not produce a result")
        }
        return value
    }
}
