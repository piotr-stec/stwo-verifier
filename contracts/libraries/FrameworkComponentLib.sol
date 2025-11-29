// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../core/CirclePoint.sol";
import "../core/CirclePointM31.sol";
import "../core/PointEvaluationAccumulator.sol";
import "../core/CanonicCoset.sol";
import "../core/CanonicCosetM31.sol";
import "../core/CosetM31.sol";
import "../fields/QM31Field.sol";
import "../framework/IFrameworkEval.sol";
import "../framework/PointEvaluatorLib.sol";
import "../framework/TreeSubspan.sol";
import "../framework/TreeVecExtensions.sol";
import "./TraceLocationAllocatorLib.sol";
import "forge-std/console.sol";

/// @title FrameworkComponentLib
/// @notice Library implementing FrameworkComponent functionality for gas optimization
/// @dev Converts contract to library to reduce deployment gas from 4M to ~400k
library FrameworkComponentLib {
    using QM31Field for QM31Field.QM31;
    using TreeSubspan for TreeSubspan.Subspan;
    using TreeVecExtensions for QM31Field.QM31[][][];
    using TraceLocationAllocatorLib for TraceLocationAllocatorLib.AllocatorState;
    using CanonicCoset for CanonicCoset.CanonicCosetStruct;
    using CanonicCosetM31 for CanonicCosetM31.CanonicCosetStruct;
    using CirclePointM31 for CirclePointM31.Point;
    using PointEvaluationAccumulator for PointEvaluationAccumulator.Accumulator;

    // =============================================================================
    // Constants matching Rust implementation
    // =============================================================================

    uint256 public constant PREPROCESSED_TRACE_IDX = 0;
    uint256 public constant ORIGINAL_TRACE_IDX = 1;
    uint256 public constant INTERACTION_TRACE_IDX = 2;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice Sample points structure for mask points generation
    /// @dev Maps to TreeVec<ColumnVec<Vec<CirclePoint<SecureField>>>> in Rust
    struct SamplePoints {
        CirclePoint.Point[][][] points; // [tree][column][mask_point]
        uint256[] nColumns; // Number of columns per tree
        uint256 totalPoints; // Total number of mask points
        CirclePoint.Point[][] preprocessed; // Convenient access to preprocessed points (tree 0)
    }

    /// @notice Component information structure
    struct ComponentInfo {
        uint256 nConstraints;
        uint32 maxConstraintLogDegreeBound;
        uint32 logSize;
        string componentName;
        string description;
        int32[][][] maskOffsets; // Mask offsets: [tree][column][offset_values] from InfoEvaluator
        uint256[] preprocessedColumns; // Preprocessed column IDs
    }

    /// @notice Framework component state
    struct ComponentState {
        /// @notice The evaluator implementing FrameworkEval
        address eval;
        /// @notice Trace locations allocated for this component
        TreeSubspan.Subspan[] traceLocations;
        /// @notice Preprocessed column indices
        uint256[] preprocessedColumnIndices;
        /// @notice Claimed sum for logup constraints
        QM31Field.QM31 claimedSum;
        /// @notice Component metadata
        ComponentInfo info;
        /// @notice Whether the component is initialized
        bool isInitialized;
    }

    // =============================================================================
    // Library Functions
    // =============================================================================

    /// @notice Create component state from precomputed ComponentInfo
    /// @dev Instead of evaluating an InfoEvaluator on-chain, accept precomputed
    ///      ComponentInfo (mask offsets, preprocessed columns, etc.) and use it to
    ///      allocate trace locations and initialize the component state.
    /// @param state Component state (will be initialized)
    /// @param allocator Location allocator (will be modified)
    /// @param evaluatorAddr Address of IFrameworkEval implementation (stored in state)
    /// @param claimedSum Claimed sum for logup constraints
    /// @param info Precomputed ComponentInfo (maskOffsets, preprocessedColumns, etc.)
    /// @return traceLocations Allocated trace locations
    /// @return preprocessedColumnIndices Indices of preprocessed columns
    /// @return returnedInfo The same ComponentInfo that was passed in
    function createComponent(
        ComponentState storage state,
        TraceLocationAllocatorLib.AllocatorState storage allocator,
        address evaluatorAddr,
        QM31Field.QM31 memory claimedSum,
        ComponentInfo memory info
    )
        external
        returns (
            TreeSubspan.Subspan[] memory traceLocations,
            uint256[] memory preprocessedColumnIndices,
            ComponentInfo memory returnedInfo
        )
    {
        require(evaluatorAddr != address(0), "Invalid evaluator address");

        // Convert mask_offsets structure to column counts for allocator
        // Rust: location_allocator.next_for_structure(&info.mask_offsets)
        // where mask_offsets is TreeVec<ColumnVec<Vec<isize>>>
        // We need to extract the number of columns per tree
        uint256[] memory treeStructure = new uint256[](info.maskOffsets.length);
        for (uint256 i = 0; i < info.maskOffsets.length; i++) {
            treeStructure[i] = info.maskOffsets[i].length; // Number of columns in this tree
        }

        // Allocate trace locations based on tree structure
        traceLocations = allocator.nextForStructure(
            treeStructure,
            ORIGINAL_TRACE_IDX
        );

        // Build preprocessed column indices from provided preprocessedColumns
        preprocessedColumnIndices = _getPreprocessedColumnIndices(
            allocator,
            info.preprocessedColumns
        );

        // Initialize component state inline (no forward-call to initialize)
        require(!state.isInitialized, "Component already initialized");
        require(traceLocations.length > 0, "No trace locations provided");
        require(info.logSize > 0, "Invalid log size");
        require(info.nConstraints > 0, "No constraints defined");

        state.eval = evaluatorAddr;
        state.claimedSum = claimedSum;
        state.info = info;
        state.isInitialized = true;

        // Store trace locations
        delete state.traceLocations;
        for (uint256 i = 0; i < traceLocations.length; i++) {
            state.traceLocations.push(traceLocations[i]);
        }

        // Store preprocessed column indices
        delete state.preprocessedColumnIndices;
        for (uint256 i = 0; i < preprocessedColumnIndices.length; i++) {
            state.preprocessedColumnIndices.push(preprocessedColumnIndices[i]);
        }

        returnedInfo = info;
    }

    /// @notice Get preprocessed column indices
    /// @dev Matches the preprocessed_column_indices logic in Rust
    function _getPreprocessedColumnIndices(
        TraceLocationAllocatorLib.AllocatorState storage allocator,
        uint256[] memory preprocessedColumns
    ) private returns (uint256[] memory indices) {
        indices = new uint256[](preprocessedColumns.length);

        for (uint256 i = 0; i < preprocessedColumns.length; i++) {
            // TODO: Implement column lookup/allocation
            // For now, just return the column index
            indices[i] = preprocessedColumns[i];
        }
    }

    /// @notice Initialize framework component state
    /// @dev Maps to: FrameworkComponent::new(location_allocator, eval, claimed_sum)
    /// @param state The component state to initialize
    /// @param _eval Framework evaluator implementing IFrameworkEval
    /// @param _traceLocations Allocated trace locations
    /// @param _preprocessedColumnIndices Indices of preprocessed columns
    /// @param _claimedSum Claimed sum for logup constraints
    /// @param _componentInfo Component metadata
    function initialize(
        ComponentState storage state,
        address _eval,
        TreeSubspan.Subspan[] memory _traceLocations,
        uint256[] memory _preprocessedColumnIndices,
        QM31Field.QM31 memory _claimedSum,
        ComponentInfo memory _componentInfo
    ) external {
        require(!state.isInitialized, "Component already initialized");
        require(_eval != address(0), "Invalid evaluator address");
        require(_traceLocations.length > 0, "No trace locations provided");
        require(_componentInfo.logSize > 0, "Invalid log size");
        require(_componentInfo.nConstraints > 0, "No constraints defined");

        state.eval = _eval;
        state.claimedSum = _claimedSum;
        state.info = _componentInfo;
        state.isInitialized = true;

        // Clear and store trace locations
        delete state.traceLocations;
        for (uint256 i = 0; i < _traceLocations.length; i++) {
            state.traceLocations.push(_traceLocations[i]);
        }

        // Clear and store preprocessed column indices
        delete state.preprocessedColumnIndices;
        for (uint256 i = 0; i < _preprocessedColumnIndices.length; i++) {
            state.preprocessedColumnIndices.push(_preprocessedColumnIndices[i]);
        }
    }

    /// @notice Get number of constraints
    /// @param state The component state
    /// @return nConstraints_ Number of constraints
    function nConstraints(
        ComponentState storage state
    ) external view returns (uint256 nConstraints_) {
        require(state.isInitialized, "Component not initialized");
        return state.info.nConstraints;
    }

    /// @notice Get maximum constraint log degree bound
    /// @param state The component state
    /// @return maxLogDegreeBound Maximum constraint log degree bound
    function maxConstraintLogDegreeBound(
        ComponentState storage state
    ) external view returns (uint32 maxLogDegreeBound) {
        require(state.isInitialized, "Component not initialized");
        return state.info.maxConstraintLogDegreeBound;
    }

    /// @notice Get trace log degree bounds
    /// @param state The component state
    /// @return bounds Trace log degree bounds for each tree
    function traceLogDegreeBounds(
        ComponentState storage state
    ) external view returns (uint32[][] memory bounds) {
        require(state.isInitialized, "Component not initialized");

        // Return log degree bounds for each tree
        bounds = new uint32[][](state.traceLocations.length);

        for (uint256 i = 0; i < state.traceLocations.length; i++) {
            uint256 numCols = state.traceLocations[i].size();
            bounds[i] = new uint32[](numCols);

            // All columns have the same log size for this component
            for (uint256 j = 0; j < numCols; j++) {
                bounds[i][j] = state.info.logSize;
            }
        }

        // Handle preprocessed columns specially (tree 0)
        if (bounds.length > 0 && state.preprocessedColumnIndices.length > 0) {
            for (
                uint256 i = 0;
                i < state.preprocessedColumnIndices.length;
                i++
            ) {
                if (i < bounds[0].length) {
                    bounds[0][i] = state.info.logSize;
                }
            }
        }

        return bounds;
    }

    function maskPoints(
        ComponentState storage state,
        CirclePoint.Point memory point
    ) external view returns (SamplePoints memory samplePoints) {
        require(state.isInitialized, "Component not initialized");

        // Rust: let trace_step = CanonicCoset::new(self.eval.log_size()).step();
        CanonicCosetM31.CanonicCosetStruct
            memory canonicCosetM31 = CanonicCosetM31.newCanonicCoset(
                IFrameworkEval(state.eval).logSize()
            );
        CirclePointM31.Point memory traceStepM31 = CanonicCosetM31.step(
            canonicCosetM31
        );

        // Initialize TreeVec structure (3 trees: PREPROCESSED, ORIGINAL_TRACE, INTERACTION)
        uint256 nTrees = 3;
        samplePoints.points = new CirclePoint.Point[][][](nTrees);
        samplePoints.nColumns = new uint256[](nTrees);
        samplePoints.totalPoints = 0;

        // Initialize all trees as empty
        for (uint256 treeIdx = 0; treeIdx < nTrees; treeIdx++) {
            samplePoints.nColumns[treeIdx] = 0;
            samplePoints.points[treeIdx] = new CirclePoint.Point[][](0);
        }

        // Apply mask_offsets logic for each column in trace locations
        // Rust: self.info.mask_offsets.as_ref().map_cols(|col_offsets| {
        //          col_offsets.iter().map(|offset| point + trace_step.mul_signed(*offset).into_ef()).collect()
        //       })

        for (
            uint256 locationIdx = 0;
            locationIdx < state.traceLocations.length;
            locationIdx++
        ) {
            TreeSubspan.Subspan memory location = state.traceLocations[
                locationIdx
            ];
            uint256 treeIdx = location.treeIndex;

            if (treeIdx < nTrees) {
                uint256 numCols = location.size();

                // Ensure tree has enough space
                if (samplePoints.points[treeIdx].length < location.colEnd) {
                    CirclePoint.Point[][]
                        memory newTree = new CirclePoint.Point[][](
                            location.colEnd
                        );
                    for (
                        uint256 i = 0;
                        i < samplePoints.points[treeIdx].length;
                        i++
                    ) {
                        newTree[i] = samplePoints.points[treeIdx][i];
                    }
                    samplePoints.points[treeIdx] = newTree;
                    samplePoints.nColumns[treeIdx] = location.colEnd;
                }

                // For each column in this component's location, get mask offsets and compute points
                for (uint256 colOffset = 0; colOffset < numCols; colOffset++) {
                    uint256 colIdx = location.colStart + colOffset;
                    if (colIdx < samplePoints.points[treeIdx].length) {
                        // Get mask offsets from ComponentInfo (computed by InfoEvaluator in Rust)
                        // Rust: self.info.mask_offsets[tree_idx][col_idx]
                        int32[] memory maskOffsets;

                        if (
                            treeIdx < state.info.maskOffsets.length &&
                            colIdx < state.info.maskOffsets[treeIdx].length
                        ) {
                            // Use offsets from ComponentInfo
                            maskOffsets = state.info.maskOffsets[treeIdx][
                                colIdx
                            ];
                        } else {
                            // Fallback: empty offsets
                            maskOffsets = new int32[](0);
                        }

                        // Create points array for this column
                        samplePoints.points[treeIdx][
                            colIdx
                        ] = new CirclePoint.Point[](maskOffsets.length);

                        // For each offset, compute: point + trace_step.mul_signed(offset).into_ef()
                        for (
                            uint256 offsetIdx = 0;
                            offsetIdx < maskOffsets.length;
                            offsetIdx++
                        ) {
                            int32 offset = maskOffsets[offsetIdx];

                            // Compute trace_step.mul_signed(offset)
                            CirclePointM31.Point
                                memory offsetPoint = CirclePointM31.mulSigned(
                                    traceStepM31,
                                    offset
                                );

                            // Convert M31 point to QM31 point (.into_ef())
                            CirclePoint.Point
                                memory offsetPointQM31 = CirclePoint.Point({
                                    x: QM31Field.fromM31(
                                        offsetPoint.x,
                                        0,
                                        0,
                                        0
                                    ),
                                    y: QM31Field.fromM31(offsetPoint.y, 0, 0, 0)
                                });

                            // Add to base point: point + offset_point
                            samplePoints.points[treeIdx][colIdx][
                                offsetIdx
                            ] = CirclePoint.add(point, offsetPointQM31);
                            samplePoints.totalPoints++;
                        }
                    }
                }
            }
        }

        // Handle preprocessed columns (tree 0)
        // Rust: for idx in component.preprocessed_column_indices() {
        //           preprocessed_mask_points[idx] = vec![point];
        //       }
        for (uint256 i = 0; i < state.preprocessedColumnIndices.length; i++) {
            uint256 colIdx = state.preprocessedColumnIndices[i];
            if (colIdx < samplePoints.points[PREPROCESSED_TRACE_IDX].length) {
                samplePoints.points[PREPROCESSED_TRACE_IDX][
                    colIdx
                ] = new CirclePoint.Point[](1);
                samplePoints.points[PREPROCESSED_TRACE_IDX][colIdx][0] = point;
                samplePoints.totalPoints++;
            }
        }

        samplePoints.preprocessed = samplePoints.points[PREPROCESSED_TRACE_IDX];

        return samplePoints;
    }

    /// @notice Get preprocessed column indices
    /// @param state The component state
    /// @return indices Preprocessed column indices
    function preprocessedColumnIndices(
        ComponentState storage state
    ) external view returns (uint256[] memory indices) {
        require(state.isInitialized, "Component not initialized");
        return state.preprocessedColumnIndices;
    }

    /// @notice Evaluate constraint quotients at point
    /// @param state The component state
    /// @param point Evaluation point
    /// @param mask Mask values
    /// @param accumulator Point evaluation accumulator
    /// @return updatedAccumulator Updated accumulator after evaluation
    function evaluateConstraintQuotientsAtPoint(
        ComponentState storage state,
        CirclePoint.Point memory point,
        QM31Field.QM31[][][] memory mask,
        PointEvaluationAccumulator.Accumulator memory accumulator
    )
        external
        returns (
            PointEvaluationAccumulator.Accumulator memory updatedAccumulator
        )
    {
        require(state.isInitialized, "Component not initialized");

        // Step 1: Extract preprocessed mask
        QM31Field.QM31[][] memory preprocessedMask = mask
            .extractPreprocessedMask(
                state.preprocessedColumnIndices,
                PREPROCESSED_TRACE_IDX
            );

        // Step 2: Create sub-tree from mask using trace locations
        QM31Field.QM31[][][] memory maskSubTree = mask.subTree(
            state.traceLocations
        );

        // Step 3: Set preprocessed mask in sub-tree
        maskSubTree = maskSubTree.setPreprocessedMask(
            preprocessedMask,
            PREPROCESSED_TRACE_IDX
        );

        // Step 4: Calculate vanishing polynomial inverse
        CanonicCosetM31.CanonicCosetStruct memory canonicCoset = CanonicCosetM31
            .newCanonicCoset(state.info.logSize);
        CosetM31.CosetStruct memory underlyingCoset = CanonicCosetM31.coset(
            canonicCoset
        );

        QM31Field.QM31 memory denomInverse = _calculateVanishingInverse(
            underlyingCoset,
            point
        );

        // Step 5: Use the accumulator directly (already correct type)
        PointEvaluationAccumulator.Accumulator
            memory pointAccumulator = accumulator;

        // Step 6: Create PointEvaluator and evaluate constraints
        PointEvaluatorLib.PointEvaluator
            memory pointEvaluator = PointEvaluatorLib.create(
                maskSubTree,
                pointAccumulator,
                denomInverse,
                state.info.logSize,
                state.claimedSum
            );

        // Step 7: Evaluate using the framework evaluator
        PointEvaluatorLib.PointEvaluator
            memory updatedEvaluator = IFrameworkEval(state.eval).evaluate(
                pointEvaluator
            );

        // Step 8: Get updated accumulator from evaluator
        PointEvaluationAccumulator.Accumulator
            memory finalAccumulator = updatedEvaluator.evaluationAccumulator;

        // Step 9: Return the updated accumulator (already correct type)
        return finalAccumulator;
    }

    /// @notice Get component information
    /// @param state The component state
    /// @return componentId Unique component identifier
    /// @return version Component version
    /// @return description Component description
    function getComponentInfo(
        ComponentState storage state
    )
        external
        view
        returns (
            bytes32 componentId,
            uint256 version,
            string memory description
        )
    {
        require(state.isInitialized, "Component not initialized");
        componentId = keccak256(bytes(state.info.componentName));
        version = 1;
        description = state.info.description;
    }

    /// @notice Validate component configuration
    /// @param state The component state
    /// @return isValid True if component is valid
    /// @return errorMessage Error message if invalid
    function validateConfiguration(
        ComponentState storage state
    ) external view returns (bool isValid, string memory errorMessage) {
        return validateComponent(state);
    }

    /// @notice Get the underlying evaluator address
    /// @param state The component state
    /// @return evaluator The framework evaluator address
    function getEval(
        ComponentState storage state
    ) external view returns (address evaluator) {
        require(state.isInitialized, "Component not initialized");
        return state.eval;
    }

    /// @notice Get trace locations
    /// @param state The component state
    /// @return locations Array of trace locations
    function getTraceLocations(
        ComponentState storage state
    ) external view returns (TreeSubspan.Subspan[] memory locations) {
        require(state.isInitialized, "Component not initialized");
        return state.traceLocations;
    }

    /// @notice Get preprocessed column indices
    /// @param state The component state
    /// @return indices Array of preprocessed column indices
    function getPreprocessedColumnIndices(
        ComponentState storage state
    ) external view returns (uint256[] memory indices) {
        require(state.isInitialized, "Component not initialized");
        return state.preprocessedColumnIndices;
    }

    /// @notice Get claimed sum
    /// @param state The component state
    /// @return sum Claimed sum for logup constraints
    function getClaimedSum(
        ComponentState storage state
    ) external view returns (QM31Field.QM31 memory sum) {
        require(state.isInitialized, "Component not initialized");
        return state.claimedSum;
    }

    /// @notice Get component info
    /// @param state The component state
    /// @return componentInfo Complete component information
    function getInfo(
        ComponentState storage state
    ) external view returns (ComponentInfo memory componentInfo) {
        require(state.isInitialized, "Component not initialized");
        return state.info;
    }

    /// @notice Clear component state after use
    /// @param state The component state to clear
    function clearState(ComponentState storage state) external {
        require(state.isInitialized, "Component not initialized");

        // Clear dynamic arrays
        delete state.traceLocations;
        delete state.preprocessedColumnIndices;

        // Reset other fields
        state.eval = address(0);
        state.claimedSum = QM31Field.zero();
        delete state.info;
        state.isInitialized = false;
    }

    /// @notice Validate component consistency
    /// @param state The component state
    /// @return isValid True if component is properly configured
    /// @return errorMessage Error description if invalid
    function validateComponent(
        ComponentState storage state
    ) public view returns (bool isValid, string memory errorMessage) {
        if (!state.isInitialized) {
            return (false, "Component not initialized");
        }

        // Check that trace locations are valid
        if (state.traceLocations.length == 0) {
            return (false, "No trace locations allocated");
        }

        // Check that evaluator is valid
        if (state.eval == address(0)) {
            return (false, "Invalid evaluator address");
        }

        // Check that info is consistent
        if (state.info.logSize == 0) {
            return (false, "Invalid log size");
        }

        if (state.info.nConstraints == 0) {
            return (false, "No constraints defined");
        }

        return (true, "Component validation passed");
    }

    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    function _calculateVanishingInverse(
        CosetM31.CosetStruct memory coset,
        CirclePoint.Point memory point
    ) internal pure returns (QM31Field.QM31 memory inverse) {
        // Implementation of coset vanishing polynomial based on Rust coset_vanishing function
        // pub fn coset_vanishing<F: ExtensionOf<BaseField>>(coset: Coset, mut p: CirclePoint<F>) -> F

        // Step 1: Rotate point to canonical form
        // Rust: p = p - coset.initial.into_ef() + coset.step_size.half().to_point().into_ef();
        CirclePoint.Point memory rotatedPoint = _rotatePointToCanonic(
            coset,
            point
        );

        // Step 2: Extract x coordinate and apply doubling iterations
        QM31Field.QM31 memory x = rotatedPoint.x;

        // Step 3: Apply double_x operation (log_size - 1) times
        // Rust: for _ in 1..coset.log_size { x = CirclePoint::double_x(x); }
        for (uint32 i = 1; i < coset.logSize; i++) {
            x = CirclePoint.doubleX(x); // x := 2x² - 1
        }

        // Step 4: Check for zero (point is on the coset)
        if (QM31Field.isZero(x)) {
            revert("Point is on coset - vanishing polynomial is zero");
        }

        // Step 5: Return multiplicative inverse of vanishing polynomial value
        return QM31Field.inverse(x);
    }

    /**
     * @notice Helper function to rotate point to canonical coset form
     * @dev Implements: p - coset.initial + coset.step_size.half().to_point()
     * @param coset The coset structure
     * @param point The original point
     * @return rotatedPoint The point after canonical rotation
     */
    function _rotatePointToCanonic(
        CosetM31.CosetStruct memory coset,
        CirclePoint.Point memory point
    ) private pure returns (CirclePoint.Point memory rotatedPoint) {
        // Convert initial M31 point to QM31 CirclePoint
        CirclePoint.Point memory initialPoint = _m31ToQM31Point(coset.initial);

        // Get step/2 as a circle point
        CirclePoint.Point memory halfStep = _getHalfStepPoint(coset);

        // Also test conjugate operation
 
        // Rust: p - coset.initial.into_ef() + coset.step_size.half().to_point().into_ef()
        rotatedPoint = CirclePoint.add(
            CirclePoint.sub(point, initialPoint),
            halfStep
        );

        return rotatedPoint;
    }

    /**
     * @notice Convert M31 CirclePoint to QM31 CirclePoint
     * @dev Convert CirclePointM31.Point to CirclePoint.Point
     * @param m31Point The M31 circle point
     * @return qm31Point The corresponding QM31 circle point
     */
    function _m31ToQM31Point(
        CirclePointM31.Point memory m31Point
    ) private pure returns (CirclePoint.Point memory qm31Point) {
        // Convert M31 coordinates to QM31
        qm31Point = CirclePoint.Point({
            x: QM31Field.fromM31(m31Point.x, 0, 0, 0),
            y: QM31Field.fromM31(m31Point.y, 0, 0, 0)
        });

        return qm31Point;
    }

    /**
     * @notice Get step_size.half().to_point() equivalent
     * @dev Gets half of the step as a circle point
     * @param coset The coset structure containing step information
     * @return halfStepPoint The half-step as a circle point
     */
    function _getHalfStepPoint(
        CosetM31.CosetStruct memory coset
    ) private pure returns (CirclePoint.Point memory halfStepPoint) {
        // Get step_size index (stored as stepSize in coset)
        uint256 stepIndex = coset.stepSize.value;

        uint256 halfStepIndex = stepIndex >> 1;

        // Rust to_point(): M31_CIRCLE_GEN.mul(index)
        // Convert index to CirclePoint by multiplying generator
        CirclePointM31.Point memory pointIndex = _indexToPoint(halfStepIndex);
        halfStepPoint = _m31ToQM31Point(pointIndex);

        return halfStepPoint;
    }

    /**
     * @notice Convert circle point index to actual circle point
     * @dev Implements M31_CIRCLE_GEN.mul(index) from Rust
     * @param index The circle point index
     * @return point The corresponding circle point
     */
    function _indexToPoint(
        uint256 index
    ) private pure returns (CirclePointM31.Point memory point) {
        // M31_CIRCLE_GEN = CirclePoint { x: M31(2), y: M31(1268011823) }
        CirclePointM31.Point memory generator = CirclePointM31.Point({
            x: 2,
            y: 1268011823
        });

        // Multiply generator by scalar index
        point = CirclePointM31.mul(generator, index);
        return point;
    }
}
