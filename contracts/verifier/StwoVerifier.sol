// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import "../framework/IFrameworkEval.sol";
import "../libraries/FrameworkComponentLib.sol";
import "../libraries/ComponentsLib.sol";
import "../libraries/TraceLocationAllocatorLib.sol";
import "../libraries/KeccakChannelLib.sol";
import "../libraries/CommitmentSchemeVerifierLib.sol";
import "../pcs/PcsConfig.sol";
import "../pcs/FriVerifier.sol";
import "../framework/TreeSubspan.sol";
import "../core/PointEvaluationAccumulator.sol";
import "../core/CirclePoint.sol";
import "../fields/QM31Field.sol";
import "../vcs/MerkleVerifier.sol";
import "./ProofParser.sol";
import "../secure_poly/SecureCirclePoly.sol";

/// @title STWOVerifier
/// @notice Generic STARK verifier for any AIR implementation
/// @dev Main entry point for proof verification matching Rust implementation
contract STWOVerifier {
    using QM31Field for QM31Field.QM31;
    using PointEvaluationAccumulator for PointEvaluationAccumulator.Accumulator;
    using FrameworkComponentLib for FrameworkComponentLib.ComponentState;
    using ComponentsLib for ComponentsLib.Components;
    using TraceLocationAllocatorLib for TraceLocationAllocatorLib.AllocatorState;
    using KeccakChannelLib for KeccakChannelLib.ChannelState;
    using CommitmentSchemeVerifierLib for CommitmentSchemeVerifierLib.VerifierState;
    using FriVerifier for FriVerifier.FriVerifierState;
    using PcsConfig for PcsConfig.Config;

    // =============================================================================
    // State Variables (used during verification)
    // =============================================================================

    /// @notice Channel state for Fiat-Shamir transform
    /// @dev Temporary state used during each verification
    KeccakChannelLib.ChannelState private _channel;

    /// @notice Commitment scheme verifier state
    /// @dev Temporary state used during each verification
    CommitmentSchemeVerifierLib.VerifierState private _commitmentScheme;

    /// @notice Trace location allocator state
    /// @dev Temporary state used during each verification
    TraceLocationAllocatorLib.AllocatorState private _allocator;

    /// @notice Components state for framework evaluation (multiple components)
    /// @dev Temporary state used during each verification
    ComponentsLib.Components private _components;

    /// @notice FRI verifier state
    /// @dev Temporary state used during FRI verification (part of PCS)
    FriVerifier.FriVerifierState private _friVerifier;

    // =============================================================================
    // Verification Parameters Structure
    // =============================================================================

    struct ComponentParams{
        uint32 logSize;
        QM31Field.QM31 claimedSum;
        FrameworkComponentLib.ComponentInfo info;
    }

    /// @notice Parameters needed for verification
    /// @dev Passed during verify() call, not stored in contract
    struct VerificationParams {
        ComponentParams[] componentParams; // Array of components to verify
        uint256 nPreprocessedColumns; // Number of preprocessed columns
        uint32 componentsCompositionLogDegreeBound; // Log degree bound for composition polynomial
    }

    // =============================================================================
    // Main Verification Function
    // =============================================================================

    /// @notice Verify a STARK proof
    /// @dev Main entry point - follows the exact flow from test_realCommitmentFlow
    /// @param proof Complete proof structure from proof.json
    /// @param params Verification parameters (evaluator address, nColumns)
    /// @return bool True if proof is valid, false otherwise
    function verify(
        ProofParser.Proof calldata proof,
        VerificationParams calldata params,
        bytes32[] memory treeRoots,
        uint32[][] memory treeColumnLogSizes,
        bytes32 digest,
        uint32 nDraws
    ) external returns (bool) {
        uint256 gas_start = gasleft();
        console.log("=== STWO PROOF VERIFICATION START ===");
        console.log("Initial gas:", gas_start);
        
        uint256 gas_before_poly = gasleft();
        SecureCirclePoly.SecurePoly memory poly = SecureCirclePoly.createSecurePoly(
            proof.compositionPoly.coeffs0, proof.compositionPoly.coeffs1, proof.compositionPoly.coeffs2, proof.compositionPoly.coeffs3
        );
        uint256 gas_after_poly = gasleft();
        console.log("Gas for SecurePoly creation:", gas_before_poly - gas_after_poly);

        // Initialize channel and commitment scheme (resets state for each verification)
        // NOTE: digest and nDraws should already include preprocessed and trace commitments
        uint256 gas_before_init = gasleft();
        KeccakChannelLib.initializeWith(_channel, digest, nDraws);
        CommitmentSchemeVerifierLib.initialize(
            _commitmentScheme,
            proof.config,
            treeRoots,
            treeColumnLogSizes
        );
        uint256 gas_after_init = gasleft();
        console.log("Gas for initialization (channel + commitment):", gas_before_init - gas_after_init);

        // =============================================================================
        // PHASE 2: Draw Random Coefficient (Interaction Phase)
        // =============================================================================

        uint256 gas_before_random = gasleft();
        QM31Field.QM31 memory randomCoeff = _channel.drawSecureFelt();
        uint256 gas_after_random = gasleft();
        console.log("Gas for drawing random coefficient:", gas_before_random - gas_after_random);

        // =============================================================================
        // PHASE 3: Composition Polynomial Commitment
        // =============================================================================

        uint256 gas_before_commit = gasleft();
        uint32[] memory compositionSizes = new uint32[](4); // SECURE_EXTENSION_DEGREE
        for (uint256 i = 0; i < 4; i++) {
            compositionSizes[i] = params.componentsCompositionLogDegreeBound;
        }
        CommitmentSchemeVerifierLib.commit(
            _commitmentScheme,
            proof.commitments[proof.commitments.length - 1], // Last commitment is composition
            compositionSizes,
            _channel
        );
        uint256 gas_after_commit = gasleft();
        console.log("Gas for composition polynomial commitment:", gas_before_commit - gas_after_commit);

        // =============================================================================
        // PHASE 4: Draw OODS Point
        // =============================================================================

        uint256 gas_before_oods_point = gasleft();
        CirclePoint.Point memory oodsPoint = CirclePoint
            .getRandomPointFromState(_channel);
        uint256 gas_after_oods_point = gasleft();
        console.log("Gas for drawing OODS point:", gas_before_oods_point - gas_after_oods_point);

        // =============================================================================
        // PHASE 5: Compute Mask Points and Sample Points
        // =============================================================================

        uint256 gas_before_sample_points = gasleft();
        ComponentsLib.TreeVecMaskPoints
            memory samplePoints = _computeSamplePoints(
                oodsPoint,
                proof.commitments.length - 1, // Exclude composition commitment (it's added internally)
                params
            );
        uint256 gas_after_sample_points = gasleft();
        console.log("Gas for computing sample points:", gas_before_sample_points - gas_after_sample_points);


        // =============================================================================
        // PHASE 6: Verify OODS Values (Out-of-Domain Sampling)
        // =============================================================================

        uint256 gas_before_extract_oods = gasleft();
        // Extract composition OODS evaluation from proof
        (
            QM31Field.QM31 memory compositionOodsEval,
            bool extractSuccess
        ) = ProofParser.extractCompositionOodsEval(proof);
        require(extractSuccess, "Failed to extract composition OODS eval");
        uint256 gas_after_extract_oods = gasleft();
        console.log("Gas for extracting composition OODS eval:", gas_before_extract_oods - gas_after_extract_oods);
        
        uint256 gas_before_oods_verify = gasleft();
        bool oodsValid = _verifyOods(
            oodsPoint,
            compositionOodsEval,
            poly
        );
        uint256 gas_after_oods_verify = gasleft();
        console.log("Gas for OODS verification:", gas_before_oods_verify - gas_after_oods_verify);

        if (!oodsValid) {
            console.log("OODS verification failed!");
            return false;
        }

        // Mix felts and generate random coeff
        uint256 gas_before_flatten = gasleft();
        QM31Field.QM31[] memory flattenedSampledValues = ProofParser
            .flattenCols(proof.sampledValues);
        uint256 gas_after_flatten = gasleft();
        console.log("Gas for flattening sampled values:", gas_before_flatten - gas_after_flatten);
        
        uint256 gas_before_mix = gasleft();
        _channel.mixFelts(flattenedSampledValues);
        uint256 gas_after_mix = gasleft();
        console.log("Gas for mixing felts into channel:", gas_before_mix - gas_after_mix);

        uint256 gas_before_random2 = gasleft();
        QM31Field.QM31 memory randomCoeff2;
        randomCoeff2 = _channel.drawSecureFelt();
        uint256 gas_after_random2 = gasleft();
        console.log("Gas for drawing second random coefficient:", gas_before_random2 - gas_after_random2);

        // Generate bounds for FRI from commitment scheme
        uint256 gas_before_bounds = gasleft();
        CirclePolyDegreeBound.Bound[] memory bounds = _commitmentScheme
            .calculateBounds();
        uint256 gas_after_bounds = gasleft();
        console.log("Gas for calculating FRI bounds:", gas_before_bounds - gas_after_bounds);

        uint256 gas_before_fri_commit = gasleft();
        _friVerifier = FriVerifier.commit(
            _channel,
            _commitmentScheme.config.friConfig,
            proof.friProof,
            bounds
        );
        uint256 gas_after_fri_commit = gasleft();
        console.log("Gas for FRI verifier commit:", gas_before_fri_commit - gas_after_fri_commit);
        // =============================================================================
        // PHASE 7: Verify Proof of Work
        // =============================================================================

        uint256 gas_before_pow = gasleft();
        bool powValid = _verifyProofOfWork(
            proof.proofOfWork,
            proof.config.powBits
        );
        uint256 gas_after_pow = gasleft();
        console.log("Gas for proof of work verification:", gas_before_pow - gas_after_pow);
        
        require(powValid, "Proof of work verification failed");
        if (!powValid) {
            console.log("Proof of work verification failed!");
            return false;
        }

        // mix pow nonce into channel
        uint256 gas_before_mix_pow = gasleft();
        _channel.mixU64(proof.proofOfWork);
        uint256 gas_after_mix_pow = gasleft();
        console.log("Gas for mixing PoW nonce into channel:", gas_before_mix_pow - gas_after_mix_pow);

        // =============================================================================
        // Create PointSamples for FRI verification
        // =============================================================================

        uint256 gas_before_zip = gasleft();
        // Rust: let samples = sampled_points.zip_cols(proof.sampled_values).map_cols(...)
        FriVerifier.PointSample[][][]
            memory pointSamples = _zipSamplePointsWithValues(
                samplePoints,
                proof.sampledValues
            );
        uint256 gas_after_zip = gasleft();
        console.log("Gas for zipping sample points with values:", gas_before_zip - gas_after_zip);

        // =============================================================================
        // PHASE 8: FRI Decommitment (PCS Verification)
        // =============================================================================
        uint256 gas_before_fri = gasleft();
        bool friValid = _verifyFri(
            proof.friProof,
            proof.config.friConfig,
            pointSamples,
            proof.decommitments,
            proof.queriedValues,
            randomCoeff2
        );
        uint256 gas_after_fri = gasleft();
        console.log("Gas for FRI verification (entire PCS):", gas_before_fri - gas_after_fri);
        
        if (!friValid) {
            console.log("FRI verification failed!");
            return false;
        }

        uint256 gas_end = gasleft();
        uint256 total_gas_used = gas_start - gas_end;
        console.log("=== VERIFICATION COMPLETE ===");
        console.log("Total gas used for entire verification:", total_gas_used);
        console.log("Final gas remaining:", gas_end);

        return true;
    }
    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    /// @notice Compute sample points for OODS evaluation
    /// @dev Follows maskPoints logic from FrameworkComponentLib
    function _computeSamplePoints(
        CirclePoint.Point memory oodsPoint,
        uint256 nTrees,
        VerificationParams calldata params
    ) internal returns (ComponentsLib.TreeVecMaskPoints memory) {
        console.log("--- Computing sample points ---");
        uint256 gas_start_compute = gasleft();
        
        uint256 gas_before_alloc = gasleft();
        FrameworkComponentLib.ComponentState[] memory componentStates = new FrameworkComponentLib.ComponentState[](params.componentParams.length);

        // Initialize allocator (reset only if already initialized)
        if (TraceLocationAllocatorLib.isInitialized(_allocator)) {
            TraceLocationAllocatorLib.reset(_allocator);
        }
        TraceLocationAllocatorLib.initialize(_allocator);
        uint256 gas_after_alloc = gasleft();
        console.log("Gas for allocator initialization:", gas_before_alloc - gas_after_alloc);
        
        uint256 gas_before_components = gasleft();
        for (uint256 i = 0; i < params.componentParams.length; i++) {
            // Reset allocator for each component to prevent accumulation
            if (i > 0) {
                TraceLocationAllocatorLib.reset(_allocator);
                TraceLocationAllocatorLib.initialize(_allocator);
            }
            
            FrameworkComponentLib.ComponentState memory componentState = FrameworkComponentLib.createComponent(_allocator, params.componentParams[i].logSize, params.componentParams[i].claimedSum, params.componentParams[i].info);
            componentStates[i] = componentState;
        }
        uint256 gas_after_components = gasleft();
        console.log("Gas for creating component states:", gas_before_components - gas_after_components);

        uint256 gas_before_init = gasleft();
        _components.initialize(componentStates, params.nPreprocessedColumns);
        uint256 gas_after_init = gasleft();
        console.log("Gas for components initialization:", gas_before_init - gas_after_init);

        // Step 1: Get mask points from each component
        // Rust: self.components.iter().map(|component| component.mask_points(point))
        uint256 gas_before_mask_points = gasleft();
        FrameworkComponentLib.SamplePoints[] memory componentMaskPoints = _components.maskPoints(oodsPoint);
        uint256 gas_after_mask_points = gasleft();
        console.log("Gas for getting mask points from components:", gas_before_mask_points - gas_after_mask_points);

        // Step 2: Concatenate columns (TreeVec::concat_cols)
        uint256 gas_before_concat = gasleft();
        ComponentsLib.TreeVecMaskPoints memory maskPoints = _concatCols(componentMaskPoints);
        uint256 gas_after_concat = gasleft();
        console.log("Gas for concatenating columns:", gas_before_concat - gas_after_concat);
        
        // Step 3: Handle preprocessed columns
        // Rust: let preprocessed_mask_points = &mut mask_points[PREPROCESSED_TRACE_IDX];
        // Rust: *preprocessed_mask_points = vec![vec![]; self.n_preprocessed_columns];
        // Calculate actual nPreprocessedColumns from componentStates
        uint256 gas_before_preproc_calc = gasleft();
        uint256 actualPreprocessedColumns = 0;
        for (uint256 i = 0; i < componentStates.length; i++) {
            actualPreprocessedColumns += componentStates[i].preprocessedColumnIndices.length;
        }
        
        _initializePreprocessedColumns(maskPoints, params.nPreprocessedColumns);
        uint256 gas_after_preproc_calc = gasleft();
        console.log("Gas for preprocessed columns setup:", gas_before_preproc_calc - gas_after_preproc_calc);

        // Step 4: Set preprocessed column mask points to [point]
        // Rust: for component in &self.components {
        //           for idx in component.preprocessed_column_indices() {
        //               preprocessed_mask_points[idx] = vec![point];
        //           }
        //       }
        uint256 gas_before_set_preproc = gasleft();
        _setPreprocessedMaskPoints(componentStates, maskPoints, oodsPoint);
        uint256 gas_after_set_preproc = gasleft();
        console.log("Gas for setting preprocessed mask points:", gas_before_set_preproc - gas_after_set_preproc);

        // Add composition polynomial tree (SECURE_EXTENSION_DEGREE = 4 columns)
        uint256 gas_before_composition = gasleft();
        CirclePoint.Point[][][] memory newPoints = new CirclePoint.Point[][][](
            nTrees + 1
        );
        uint256[] memory newNColumns = new uint256[](nTrees + 1);

        // Copy existing trees from maskPoints
        for (uint256 i = 0; i < maskPoints.points.length; i++) {
            newPoints[i] = maskPoints.points[i];
            newNColumns[i] = maskPoints.nColumnsPerTree[i];
        }

        // Add composition tree (Rust: sample_points.push(vec![vec![oods_point]; SECURE_EXTENSION_DEGREE]))
        uint256 compositionTreeIdx = nTrees;
        uint256 SECURE_EXTENSION_DEGREE = 4;
        newPoints[compositionTreeIdx] = new CirclePoint.Point[][](SECURE_EXTENSION_DEGREE);
        newNColumns[compositionTreeIdx] = SECURE_EXTENSION_DEGREE;

        for (uint256 colIdx = 0; colIdx < SECURE_EXTENSION_DEGREE; colIdx++) {
            newPoints[compositionTreeIdx][colIdx] = new CirclePoint.Point[](1);
            newPoints[compositionTreeIdx][colIdx][0] = oodsPoint;
            maskPoints.totalPoints++;
        }

        // Update maskPoints with composition tree
        maskPoints.points = newPoints;
        maskPoints.nColumnsPerTree = newNColumns;
        uint256 gas_after_composition = gasleft();
        console.log("Gas for adding composition tree:", gas_before_composition - gas_after_composition);
        
        uint256 gas_end_compute = gasleft();
        console.log("Total gas for _computeSamplePoints:", gas_start_compute - gas_end_compute);
        
        return maskPoints;
    }

    /// @notice Get n_columns_per_log_size for each tree (matching Rust BTreeMap<u32, usize>)
    /// @param scheme The commitment scheme state
    /// @return Array of [logSize, nColumns] pairs for each tree
    function getNColumnsPerLogSize(
        CommitmentSchemeVerifierLib.VerifierState storage scheme
    ) internal view returns (uint32[][][] memory) {
        uint32[][][] memory result = new uint32[][][](
            scheme.columnLogSizes().length
        );

        for (
            uint256 treeIdx = 0;
            treeIdx < scheme.columnLogSizes().length;
            treeIdx++
        ) {
            uint32[] memory columnLogSizes = scheme.columnLogSizes()[treeIdx];

            if (columnLogSizes.length == 0) {
                result[treeIdx] = new uint32[][](0);
                continue;
            }

            // Count unique log sizes and their occurrences (equivalent to BTreeMap)
            // First, find unique log sizes
            uint32[] memory uniqueLogSizes = _getUniqueLogSizes(columnLogSizes);

            // Create result array for this tree
            result[treeIdx] = new uint32[][](uniqueLogSizes.length);

            // For each unique log size, count occurrences
            for (uint256 i = 0; i < uniqueLogSizes.length; i++) {
                uint32 logSize = uniqueLogSizes[i];
                uint32 count = 0;

                // Count how many columns have this log size
                for (uint256 j = 0; j < columnLogSizes.length; j++) {
                    if (columnLogSizes[j] == logSize) {
                        count++;
                    }
                }

                // Store [logSize, count] pair
                result[treeIdx][i] = new uint32[](2);
                result[treeIdx][i][0] = logSize;
                result[treeIdx][i][1] = count;
            }
        }

        return result;
    }

    /// @notice Concatenate columns from multiple component mask points (TreeVec::concat_cols)
    /// @param componentMaskPoints Array of mask points from each component
    /// @return concatenated TreeVec with concatenated columns
    function _concatCols(
        FrameworkComponentLib.SamplePoints[] memory componentMaskPoints
    ) internal pure returns (ComponentsLib.TreeVecMaskPoints memory concatenated) {
        if (componentMaskPoints.length == 0) {
            concatenated.nColumnsPerTree = new uint256[](3); // 3 trees
            concatenated.points = new CirclePoint.Point[][][](3);
            concatenated.totalPoints = 0;
            return concatenated;
        }

        uint256 nTrees = 3; // PREPROCESSED, ORIGINAL_TRACE, INTERACTION
        concatenated.nColumnsPerTree = new uint256[](nTrees);
        concatenated.totalPoints = 0;

        // Calculate total columns per tree
        for (uint256 compIdx = 0; compIdx < componentMaskPoints.length; compIdx++) {
            for (uint256 treeIdx = 0; treeIdx < nTrees && treeIdx < componentMaskPoints[compIdx].nColumns.length; treeIdx++) {
                concatenated.nColumnsPerTree[treeIdx] += componentMaskPoints[compIdx].nColumns[treeIdx];
            }
            concatenated.totalPoints += componentMaskPoints[compIdx].totalPoints;
        }

        // Allocate concatenated structure
        concatenated.points = new CirclePoint.Point[][][](nTrees);
        for (uint256 treeIdx = 0; treeIdx < nTrees; treeIdx++) {
            concatenated.points[treeIdx] = new CirclePoint.Point[][](concatenated.nColumnsPerTree[treeIdx]);
        }

        // Copy data from all components
        uint256[] memory currentColIndex = new uint256[](nTrees);
        for (uint256 compIdx = 0; compIdx < componentMaskPoints.length; compIdx++) {
            for (uint256 treeIdx = 0; treeIdx < nTrees && treeIdx < componentMaskPoints[compIdx].points.length; treeIdx++) {
                for (uint256 colIdx = 0; colIdx < componentMaskPoints[compIdx].points[treeIdx].length; colIdx++) {
                    uint256 targetColIdx = currentColIndex[treeIdx];
                    if (targetColIdx < concatenated.points[treeIdx].length) {
                        concatenated.points[treeIdx][targetColIdx] = componentMaskPoints[compIdx].points[treeIdx][colIdx];
                        currentColIndex[treeIdx]++;
                    }
                }
            }
        }
        return concatenated;
    }

    /// @notice Initialize preprocessed columns with empty vectors
    /// @param maskPoints The mask points structure to modify
    /// @param nPreprocessedColumns Number of preprocessed columns  
    function _initializePreprocessedColumns(
        ComponentsLib.TreeVecMaskPoints memory maskPoints,
        uint256 nPreprocessedColumns
    ) internal pure {
        if (maskPoints.points.length > 0) {
            CirclePoint.Point[][] memory preprocessedTree = new CirclePoint.Point[][](nPreprocessedColumns);
            for (uint256 i = 0; i < nPreprocessedColumns; i++) {
                preprocessedTree[i] = new CirclePoint.Point[](0);
            }
            maskPoints.points[0] = preprocessedTree; // PREPROCESSED_TRACE_IDX = 0
            maskPoints.nColumnsPerTree[0] = nPreprocessedColumns;
        }
    }

    /// @notice Set preprocessed mask points to [point] for each component's preprocessed columns
    /// @param components Array of component states
    /// @param maskPoints The mask points structure to modify
    /// @param point The point to set for preprocessed columns
    function _setPreprocessedMaskPoints(
        FrameworkComponentLib.ComponentState[] memory components,
        ComponentsLib.TreeVecMaskPoints memory maskPoints,
        CirclePoint.Point memory point
    ) internal pure {
        for (uint256 compIdx = 0; compIdx < components.length; compIdx++) {
            uint256[] memory preprocessedIndices = components[compIdx].preprocessedColumnIndices;
            
            for (uint256 i = 0; i < preprocessedIndices.length; i++) {
                uint256 colIdx = preprocessedIndices[i];
                if (colIdx < maskPoints.points[0].length) { // PREPROCESSED_TRACE_IDX = 0
                    maskPoints.points[0][colIdx] = new CirclePoint.Point[](1);
                    maskPoints.points[0][colIdx][0] = point;
                }
            }
        }
    }

    /// @notice Get unique log sizes from array (helper for getNColumnsPerLogSize)
    /// @param logSizes Array of log sizes (may contain duplicates)
    /// @return Array of unique log sizes in ascending order
    function _getUniqueLogSizes(
        uint32[] memory logSizes
    ) internal pure returns (uint32[] memory) {
        if (logSizes.length == 0) {
            return new uint32[](0);
        }

        // Sort the array first
        uint32[] memory sorted = new uint32[](logSizes.length);
        for (uint256 i = 0; i < logSizes.length; i++) {
            sorted[i] = logSizes[i];
        }
        _sortUint32ArrayHelper(sorted);

        // Remove duplicates
        return _removeDuplicatesUint32Helper(sorted);
    }

    /// @notice Sort uint32 array helper
    function _sortUint32ArrayHelper(uint32[] memory arr) internal pure {
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = 0; j < arr.length - i - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    uint32 temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
    }

    /// @notice Remove consecutive duplicates helper
    function _removeDuplicatesUint32Helper(
        uint32[] memory sortedArr
    ) internal pure returns (uint32[] memory) {
        if (sortedArr.length == 0) {
            return new uint32[](0);
        }

        // Count unique elements
        uint256 uniqueCount = 1;
        for (uint256 i = 1; i < sortedArr.length; i++) {
            if (sortedArr[i] != sortedArr[i - 1]) {
                uniqueCount++;
            }
        }

        // Create deduplicated array
        uint32[] memory deduplicated = new uint32[](uniqueCount);
        deduplicated[0] = sortedArr[0];
        uint256 currentIndex = 1;

        for (uint256 i = 1; i < sortedArr.length; i++) {
            if (sortedArr[i] != sortedArr[i - 1]) {
                deduplicated[currentIndex] = sortedArr[i];
                currentIndex++;
            }
        }

        return deduplicated;
    }

    /// @notice Zip sample points with sampled values to create PointSample structure
    /// @dev Rust: sampled_points.zip_cols(proof.sampled_values).map_cols(...)
    /// Creates PointSample[tree][column][sample_index] from points and values
    /// @param samplePoints Sample points structure (tree -> column -> point)
    /// @param sampledValues Sampled values from proof (tree -> column -> value)
    /// @return samples Array of PointSample structures [tree][column][sample]
    function _zipSamplePointsWithValues(
        ComponentsLib.TreeVecMaskPoints memory samplePoints,
        QM31Field.QM31[][][] memory sampledValues
    ) internal pure returns (FriVerifier.PointSample[][][] memory samples) {

        require(
            samplePoints.points.length == sampledValues.length,
            "Tree count mismatch"
        );

        samples = new FriVerifier.PointSample[][][](samplePoints.points.length);

        // For each tree
        for (
            uint256 treeIdx = 0;
            treeIdx < samplePoints.points.length;
            treeIdx++
        ) {
            require(
                samplePoints.points[treeIdx].length ==
                    sampledValues[treeIdx].length,
                "Column count mismatch"
            );

            samples[treeIdx] = new FriVerifier.PointSample[][](
                samplePoints.points[treeIdx].length
            );

            // For each column
            for (
                uint256 colIdx = 0;
                colIdx < samplePoints.points[treeIdx].length;
                colIdx++
            ) {
                CirclePoint.Point[] memory columnPoints = samplePoints.points[
                    treeIdx
                ][colIdx];
                QM31Field.QM31[] memory columnValues = sampledValues[treeIdx][
                    colIdx
                ];

                require(
                    columnPoints.length == columnValues.length,
                    "Sample count mismatch"
                );

                samples[treeIdx][colIdx] = new FriVerifier.PointSample[](
                    columnPoints.length
                );

                // Zip points with values: zip(sampled_points, sampled_values).map(|(point, value)| PointSample { point, value })
                for (
                    uint256 sampleIdx = 0;
                    sampleIdx < columnPoints.length;
                    sampleIdx++
                ) {
                    samples[treeIdx][colIdx][sampleIdx] = FriVerifier
                        .PointSample({
                            point: columnPoints[sampleIdx],
                            value: columnValues[sampleIdx]
                        });
                }
            }
        }

        return samples;
    }

    /// @notice Verify OODS (out-of-domain sampling) values
    /// @dev Checks that claimed evaluations match the constraint polynomial
    function _verifyOods(
        CirclePoint.Point memory oodsPoint,
        QM31Field.QM31 memory compositionOodsEval,
        SecureCirclePoly.SecurePoly memory poly
    ) internal returns (bool) {
   
    
        QM31Field.QM31 memory finalResult = SecureCirclePoly.evalAtPoint(poly, oodsPoint);
        
        // 3. Verify constraint evaluations
        require(
            QM31Field.eq(finalResult, compositionOodsEval),
            "OODS values do not match"
        );
        return true;
    }

    /// @notice Verify proof of work
    /// @dev Checks that the PoW nonce produces a valid hash
    event PoWVerification(uint64 nonce, uint32 powBits, bool result);

    function _verifyProofOfWork(
        uint64 nonce,
        uint32 powBits
    ) internal returns (bool) {
        bool powResult = _channel.verifyPowNonce(powBits, nonce);
        emit PoWVerification(nonce, powBits, powResult);
        return powResult;
    }

    /// @notice Verify FRI proof
    /// @dev Main FRI decommitment verification
    function _verifyFri(
        FriVerifier.FriProof memory friProof,
        PcsConfig.FriConfig memory friConfig,
        FriVerifier.PointSample[][][] memory pointSamples,
        MerkleVerifier.Decommitment[] memory decommitments,
        uint32[][] memory queriedValues,
        QM31Field.QM31 memory randomCoeff
    ) internal returns (bool) {
        console.log("--- Starting FRI verification ---");
        uint256 gas_start_fri = gasleft();
        
        // Get FRI query positions (equivalent to fri_verifier.sample_query_positions(channel))
        uint256 gas_before_query_pos = gasleft();
        FriVerifier.QueryPositionsByLogSize memory queryPositions = _friVerifier
            .sampleQueryPositions(_channel);
        uint256 gas_after_query_pos = gasleft();
        console.log("Gas for sampling query positions:", gas_before_query_pos - gas_after_query_pos);

        // Verify merkle decommitments (equivalent to Rust tree verification loop)
        // self.trees.as_ref().zip_eq(proof.decommitments).zip_eq(proof.queried_values.clone())
        //     .map(|((tree, decommitment), queried_values)| tree.verify(...))
        uint256 gas_before_merkle = gasleft();
        bool merkleVerificationSuccess = _verifyMerkleDecommitments(
            decommitments,
            queriedValues,
            queryPositions
        );
        uint256 gas_after_merkle = gasleft();
        console.log("Gas for Merkle decommitments verification:", gas_before_merkle - gas_after_merkle);

        if (!merkleVerificationSuccess) {
            console.log("Merkle decommitments verification failed!");
            return false;
        }        
        // Answer FRI queries (equivalent to fri_answers call)
        uint256 gas_before_columns_info = gasleft();
        uint32[][][] memory nColumnsPerLogSizeData = getNColumnsPerLogSize(
            _commitmentScheme
        );
        
        uint32[][] memory commitmentColumnLogSizes = _commitmentScheme
            .columnLogSizes();
        uint256 gas_after_columns_info = gasleft();
        console.log("Gas for getting columns info:", gas_before_columns_info - gas_after_columns_info);
            
        QM31Field.QM31[][] memory friAnswersResult = FriVerifier.friAnswers(
            commitmentColumnLogSizes,
            pointSamples,
            randomCoeff,
            queryPositions,
            queriedValues,
            nColumnsPerLogSizeData
        );
        
        console.log("friAnswers completed, friAnswersResult.length:", friAnswersResult.length);

        // FRI decommit verification
        console.log("About to call FriVerifier.decommit");
        bool decommitSuccess = FriVerifier.decommit(
            _friVerifier,
            friAnswersResult
        );

        uint256 gas_end_fri = gasleft();
        console.log("Total gas for _verifyFri:", gas_start_fri - gas_end_fri);
        
        return decommitSuccess;
    }

    /// @notice External wrapper for MerkleVerifier.verify to enable try/catch
    /// @dev External function required for try/catch pattern in Solidity
    function _verifyTreeDecommitment(
        MerkleVerifier.MerkleTree memory tree,
        MerkleVerifier.QueriesPerLogSize[] memory queriesPerLogSize,
        uint32[] memory queriedValues,
        MerkleVerifier.Decommitment memory decommitment
    ) internal pure {
        MerkleVerifier.verify(
            tree,
            queriesPerLogSize,
            queriedValues,
            decommitment
        );
    }

    /// @notice Verify Merkle tree decommitments for all trees
    /// @dev Equivalent to Rust: self.trees.as_ref().zip_eq(proof.decommitments).zip_eq(proof.queried_values.clone())
    ///      .map(|((tree, decommitment), queried_values)| tree.verify(&query_positions_per_log_size, queried_values, decommitment))
    /// @param decommitments Array of Merkle decommitments (one per tree)
    /// @param queriedValues Array of queried values (one per tree)
    /// @param queryPositions Query positions organized by log size
    /// @return success True if all tree verifications pass
    function _verifyMerkleDecommitments(
        MerkleVerifier.Decommitment[] memory decommitments,
        uint32[][] memory queriedValues,
        FriVerifier.QueryPositionsByLogSize memory queryPositions
    ) internal view returns (bool success) {
        
        // Get trees from commitment scheme (equivalent to self.trees.as_ref())
        uint32[][] memory treesColumnLogSizes = _commitmentScheme
            .columnLogSizes();

        // Verify length consistency (equivalent to zip_eq checks in Rust)
        require(
            decommitments.length == treesColumnLogSizes.length,
            "Decommitments count mismatch"
        );
        require(
            queriedValues.length == treesColumnLogSizes.length,
            "Queried values count mismatch"
        );

        // Verify each tree: tree.verify(&query_positions_per_log_size, queried_values, decommitment)
        for (
            uint256 treeIdx = 0;
            treeIdx < treesColumnLogSizes.length;
            treeIdx++
        ) {            
            // Create MerkleTree structure (equivalent to tree in Rust)
            uint32[] memory columnLogSizes = treesColumnLogSizes[treeIdx];
            (
                uint32[] memory logSizes,
                uint256[] memory nColumnsPerLogSize
            ) = _getTreeLogSizeInfo(columnLogSizes);

            MerkleVerifier.MerkleTree memory tree = MerkleVerifier.MerkleTree({
                root: _commitmentScheme.getTreeRoot(treeIdx),
                columnLogSizes: columnLogSizes,
                logSizes: logSizes,
                nColumnsPerLogSize: nColumnsPerLogSize
            });

            // Filter query positions to only those relevant for this tree's log sizes
            MerkleVerifier.QueriesPerLogSize[]
                memory queriesPerLogSize = _filterQueryPositionsForTree(
                    queryPositions,
                    logSizes
                );
            // Verify this tree's decommitment (throws on failure, so we use try/catch)
            _verifyTreeDecommitment(
                tree,
                queriesPerLogSize,
                queriedValues[treeIdx],
                decommitments[treeIdx]
            );
            
        }

        return true;
    }

    /// @notice Convert FriVerifier.QueryPositionsByLogSize to MerkleVerifier.QueriesPerLogSize format
    /// @param queryPositions Query positions from FRI verifier
    /// @return queriesPerLogSize Array in MerkleVerifier format
    function _convertQueryPositions(
        FriVerifier.QueryPositionsByLogSize memory queryPositions
    )
        internal
        pure
        returns (MerkleVerifier.QueriesPerLogSize[] memory queriesPerLogSize)
    {
        queriesPerLogSize = new MerkleVerifier.QueriesPerLogSize[](
            queryPositions.logSizes.length
        );

        for (uint256 i = 0; i < queryPositions.logSizes.length; i++) {
            queriesPerLogSize[i] = MerkleVerifier.QueriesPerLogSize({
                logSize: queryPositions.logSizes[i],
                queries: queryPositions.queryPositions[i]
            });
        }
    }

    /// @notice Filter query positions to only include those relevant for a specific tree
    /// @param queryPositions All query positions from FRI verifier
    /// @param treeLogSizes Unique log sizes present in this tree
    /// @return filtered Array with only queries for log sizes present in the tree
    function _filterQueryPositionsForTree(
        FriVerifier.QueryPositionsByLogSize memory queryPositions,
        uint32[] memory treeLogSizes
    )
        internal
        pure
        returns (MerkleVerifier.QueriesPerLogSize[] memory filtered)
    {
        // Count how many log sizes from queryPositions are in treeLogSizes
        uint256 matchCount = 0;
        for (uint256 i = 0; i < queryPositions.logSizes.length; i++) {
            for (uint256 j = 0; j < treeLogSizes.length; j++) {
                if (queryPositions.logSizes[i] == treeLogSizes[j]) {
                    matchCount++;
                    break;
                }
            }
        }

        // Create filtered array with only matching log sizes
        filtered = new MerkleVerifier.QueriesPerLogSize[](matchCount);
        uint256 filteredIdx = 0;

        for (uint256 i = 0; i < queryPositions.logSizes.length; i++) {
            for (uint256 j = 0; j < treeLogSizes.length; j++) {
                if (queryPositions.logSizes[i] == treeLogSizes[j]) {
                    filtered[filteredIdx] = MerkleVerifier.QueriesPerLogSize({
                        logSize: queryPositions.logSizes[i],
                        queries: queryPositions.queryPositions[i]
                    });
                    filteredIdx++;
                    break;
                }
            }
        }
    }

    /// @notice Get log size information for a single tree (helper for MerkleTree construction)
    /// @param columnLogSizes Array of column log sizes for one tree
    /// @return logSizes Unique log sizes in ascending order
    /// @return nColumnsPerLogSize Count of columns per each unique log size
    function _getTreeLogSizeInfo(
        uint32[] memory columnLogSizes
    )
        internal
        pure
        returns (uint32[] memory logSizes, uint256[] memory nColumnsPerLogSize)
    {
        // Get unique log sizes (reuse existing helper function)
        logSizes = _getUniqueLogSizes(columnLogSizes);

        // Count columns per log size
        nColumnsPerLogSize = new uint256[](logSizes.length);
        for (uint256 i = 0; i < logSizes.length; i++) {
            uint32 currentLogSize = logSizes[i];
            uint256 count = 0;

            for (uint256 j = 0; j < columnLogSizes.length; j++) {
                if (columnLogSizes[j] == currentLogSize) {
                    count++;
                }
            }

            nColumnsPerLogSize[i] = count;
        }
    }
}
