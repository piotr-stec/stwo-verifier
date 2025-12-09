// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../core/CirclePoint.sol";
import "../fields/QM31Field.sol";
import "../framework/TreeSubspan.sol";
import "./FrameworkComponentLib.sol";
import "forge-std/console.sol";


/// @title ComponentsLib
/// @notice Library implementing Components functionality based on Rust stwo Components struct
/// @dev Provides composition_log_degree_bound and mask_points functions for multiple components
library ComponentsLib {
    using QM31Field for QM31Field.QM31;
    using FrameworkComponentLib for FrameworkComponentLib.ComponentState;

    // =============================================================================
    // Constants
    // =============================================================================

    uint256 public constant PREPROCESSED_TRACE_IDX = 0;
    uint256 public constant ORIGINAL_TRACE_IDX = 1;
    uint256 public constant INTERACTION_TRACE_IDX = 2;

    // =============================================================================
    // Data Structures
    // =============================================================================

    /// @notice Components structure matching Rust implementation
    /// @dev Equivalent to: pub struct Components<'a> { pub components: Vec<&'a dyn Component>, pub n_preprocessed_columns: usize }
    struct Components {
        FrameworkComponentLib.ComponentState[] components;
        uint256 nPreprocessedColumns;
        bool isInitialized;
    }

    /// @notice TreeVec structure for mask points
    /// @dev Maps to TreeVec<ColumnVec<Vec<CirclePoint<SecureField>>>> in Rust
    struct TreeVecMaskPoints {
        CirclePoint.Point[][][] points; // [tree][column][point]
        uint256[] nColumnsPerTree; // Number of columns per tree
        uint256 totalPoints; // Total number of mask points
    }

    // =============================================================================
    // Events
    // =============================================================================

    event ComponentsInitialized(uint256 nComponents, uint256 nPreprocessedColumns);
    event CompositionLogDegreeBoundCalculated(uint32 maxBound);
    event MaskPointsGenerated(uint256 totalPoints, uint256 nTrees);

    // =============================================================================
    // Library Functions
    // =============================================================================

    /// @notice Initialize components structure
    /// @param components_ The components struct to initialize
    /// @param componentStates Array of component states
    /// @param nPreprocessedColumns_ Number of preprocessed columns
    function initialize(
        Components storage components_,
        FrameworkComponentLib.ComponentState[] memory componentStates,
        uint256 nPreprocessedColumns_
    ) external {  
        require(!components_.isInitialized, "Components already initialized");

        require(componentStates.length > 0, "No components provided");

        // Clear existing components
        delete components_.components;


        // Copy component states
        for (uint256 i = 0; i < componentStates.length; i++) {
            components_.components.push();
            FrameworkComponentLib.ComponentState storage dest = components_.components[i];
            FrameworkComponentLib.ComponentState memory src = componentStates[i];
            
            // Copy component state data
            dest.logSize = src.logSize;
            dest.claimedSum = src.claimedSum;
            dest.info = src.info;
            dest.isInitialized = src.isInitialized;

            // Copy trace locations
            for (uint256 j = 0; j < src.traceLocations.length; j++) {
                dest.traceLocations.push(src.traceLocations[j]);
            }

            // Note: preprocessedColumnIndices will be set during component initialization
        }


        components_.nPreprocessedColumns = nPreprocessedColumns_;
        components_.isInitialized = true;

        emit ComponentsInitialized(componentStates.length, nPreprocessedColumns_);

    }

    /// @notice Get composition log degree bound
    /// @dev Equivalent to Rust: composition_log_degree_bound(&self) -> u32
    /// @param components_ The components struct
    /// @return maxBound Maximum constraint log degree bound across all components
    function compositionLogDegreeBound(
        Components storage components_
    ) external view returns (uint32 maxBound) {
        require(components_.isInitialized, "Components not initialized");
        require(components_.components.length > 0, "No components available");

        // Rust: self.components.iter().map(|component| component.max_constraint_log_degree_bound()).max().unwrap()
        maxBound = 0;
        
        for (uint256 i = 0; i < components_.components.length; i++) {
            uint32 componentBound = FrameworkComponentLib.maxConstraintLogDegreeBound(
                components_.components[i]
            );
            
            if (componentBound > maxBound) {
                maxBound = componentBound;
            }
        }

        require(maxBound > 0, "No valid constraint bounds found");
        
        return maxBound;
    }

    /// @notice Generate mask points for all components
    /// @dev Equivalent to Rust: mask_points(&self, point: CirclePoint<SecureField>) -> TreeVec<ColumnVec<Vec<CirclePoint<SecureField>>>>
    /// @param components_ The components struct
    /// @param point The circle point to generate mask points for
    /// @return componentMaskPoints Array containing mask points for each component
    function maskPoints(
        Components storage components_,
        CirclePoint.Point memory point
    ) external view returns (FrameworkComponentLib.SamplePoints[] memory componentMaskPoints) {

        require(components_.isInitialized, "Components not initialized");

        require(components_.components.length > 0, "No components available");

        // Step 1: Collect mask points from all components
        // Rust: let mut mask_points = TreeVec::concat_cols(self.components.iter().map(|component| component.mask_points(point)))
        componentMaskPoints = new FrameworkComponentLib.SamplePoints[](components_.components.length);

        // Get mask points from each component
        for (uint256 i = 0; i < components_.components.length; i++) {
            componentMaskPoints[i] = FrameworkComponentLib.maskPoints(
                components_.components[i],
                point
            );
        }

        return componentMaskPoints;
    }

    /// @notice Get number of components
    /// @param components_ The components struct
    /// @return count Number of components
    function getComponentCount(
        Components storage components_
    ) external view returns (uint256 count) {
        require(components_.isInitialized, "Components not initialized");
        return components_.components.length;
    }

    /// @notice Get component state by index
    /// @param components_ The components struct
    /// @param index Component index
    /// @return componentState The component state
    function getComponent(
        Components storage components_,
        uint256 index
    ) external view returns (FrameworkComponentLib.ComponentState memory componentState) {
        require(components_.isInitialized, "Components not initialized");
        require(index < components_.components.length, "Component index out of bounds");
        
        return components_.components[index];
    }

    /// @notice Get number of preprocessed columns
    /// @param components_ The components struct
    /// @return count Number of preprocessed columns
    function getPreprocessedColumnCount(
        Components storage components_
    ) external view returns (uint256 count) {
        require(components_.isInitialized, "Components not initialized");
        return components_.nPreprocessedColumns;
    }


    /// @notice Validate all components
    /// @param components_ The components struct
    /// @return isValid True if all components are valid
    /// @return errorMessage Error message if any component is invalid
    function validateAllComponents(
        Components storage components_
    ) external view returns (bool isValid, string memory errorMessage) {
        require(components_.isInitialized, "Components not initialized");
        
        for (uint256 i = 0; i < components_.components.length; i++) {
            (bool componentValid, string memory componentError) = FrameworkComponentLib.validateComponent(
                components_.components[i]
            );
            
            if (!componentValid) {
                return (false, string(abi.encodePacked("Component ", _toString(i), ": ", componentError)));
            }
        }
        
        return (true, "All components valid");
    }

    /// @notice Clear components structure
    /// @param components_ The components struct to clear
    function clear(Components storage components_) external {
        require(components_.isInitialized, "Components not initialized");
        
        // Clear all component states
        for (uint256 i = 0; i < components_.components.length; i++) {
            FrameworkComponentLib.clearState(components_.components[i]);
        }
        
        delete components_.components;
        components_.nPreprocessedColumns = 0;
        components_.isInitialized = false;
    }

    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    /// @notice Concatenate columns from multiple component mask points
    /// @dev Implements TreeVec::concat_cols functionality
    /// @param componentMaskPoints Array of mask points from each component
    /// @return concatenated TreeVec with concatenated columns
    function _concatCols(
        FrameworkComponentLib.SamplePoints[] memory componentMaskPoints
    ) private pure returns (TreeVecMaskPoints memory concatenated) {
        if (componentMaskPoints.length == 0) {
            // Return empty structure
            concatenated.nColumnsPerTree = new uint256[](3); // 3 trees
            concatenated.points = new CirclePoint.Point[][][](3);
            concatenated.totalPoints = 0;
            return concatenated;
        }

        // Determine maximum number of trees and total columns per tree
        uint256 nTrees = 3; // PREPROCESSED, ORIGINAL_TRACE, INTERACTION
        concatenated.nColumnsPerTree = new uint256[](nTrees);
        concatenated.totalPoints = 0;

        // Calculate total columns per tree across all components
        for (uint256 compIdx = 0; compIdx < componentMaskPoints.length; compIdx++) {
            FrameworkComponentLib.SamplePoints memory compPoints = componentMaskPoints[compIdx];
            
            for (uint256 treeIdx = 0; treeIdx < nTrees && treeIdx < compPoints.nColumns.length; treeIdx++) {
                concatenated.nColumnsPerTree[treeIdx] += compPoints.nColumns[treeIdx];
            }
            concatenated.totalPoints += compPoints.totalPoints;
        }

        // Allocate concatenated structure
        concatenated.points = new CirclePoint.Point[][][](nTrees);
        for (uint256 treeIdx = 0; treeIdx < nTrees; treeIdx++) {
            concatenated.points[treeIdx] = new CirclePoint.Point[][](concatenated.nColumnsPerTree[treeIdx]);
        }

        // Copy data from all components
        uint256[] memory currentColIndex = new uint256[](nTrees); // Track current column index per tree
        
        for (uint256 compIdx = 0; compIdx < componentMaskPoints.length; compIdx++) {
            FrameworkComponentLib.SamplePoints memory compPoints = componentMaskPoints[compIdx];
            
            for (uint256 treeIdx = 0; treeIdx < nTrees && treeIdx < compPoints.points.length; treeIdx++) {
                for (uint256 colIdx = 0; colIdx < compPoints.points[treeIdx].length; colIdx++) {
                    uint256 targetColIdx = currentColIndex[treeIdx];
                    
                    if (targetColIdx < concatenated.points[treeIdx].length) {
                        concatenated.points[treeIdx][targetColIdx] = compPoints.points[treeIdx][colIdx];
                        currentColIndex[treeIdx]++;
                    }
                }
            }
        }

        return concatenated;
    }

    /// @notice Initialize preprocessed columns with empty vectors
    /// @dev Rust: *preprocessed_mask_points = vec![vec![]; self.n_preprocessed_columns];
    /// @param maskPoints The mask points structure to modify
    /// @param nPreprocessedColumns Number of preprocessed columns
    function _initializePreprocessedColumns(
        TreeVecMaskPoints memory maskPoints,
        uint256 nPreprocessedColumns
    ) private pure {
        // Ensure preprocessed tree exists and has the right size
        if (maskPoints.points.length > PREPROCESSED_TRACE_IDX) {
            // Resize preprocessed tree to exact number of preprocessed columns
            CirclePoint.Point[][] memory preprocessedTree = new CirclePoint.Point[][](nPreprocessedColumns);
            
            // Initialize each column as empty
            for (uint256 i = 0; i < nPreprocessedColumns; i++) {
                preprocessedTree[i] = new CirclePoint.Point[](0);
            }
            
            maskPoints.points[PREPROCESSED_TRACE_IDX] = preprocessedTree;
            maskPoints.nColumnsPerTree[PREPROCESSED_TRACE_IDX] = nPreprocessedColumns;
        }
    }

    /// @notice Set preprocessed mask points to [point] for each component's preprocessed columns
    /// @dev Rust: for idx in component.preprocessed_column_indices() { preprocessed_mask_points[idx] = vec![point]; }
    /// @param components_ The components struct
    /// @param maskPoints The mask points structure to modify
    /// @param point The point to set for preprocessed columns
    function _setPreprocessedMaskPoints(
        Components storage components_,
        TreeVecMaskPoints memory maskPoints,
        CirclePoint.Point memory point
    ) private view {
        // Iterate through all components and their preprocessed column indices
        for (uint256 compIdx = 0; compIdx < components_.components.length; compIdx++) {
            uint256[] memory preprocessedIndices = FrameworkComponentLib.getPreprocessedColumnIndices(
                components_.components[compIdx]
            );
            
            // For each preprocessed column index, set mask_points[idx] = [point]
            for (uint256 i = 0; i < preprocessedIndices.length; i++) {
                uint256 colIdx = preprocessedIndices[i];
                
                if (colIdx < maskPoints.points[PREPROCESSED_TRACE_IDX].length) {
                    // Set this column to contain exactly one point
                    maskPoints.points[PREPROCESSED_TRACE_IDX][colIdx] = new CirclePoint.Point[](1);
                    maskPoints.points[PREPROCESSED_TRACE_IDX][colIdx][0] = point;
                }
            }
        }
    }

    /// @notice Convert uint256 to string
    /// @param value The value to convert
    /// @return str String representation
    function _toString(uint256 value) private pure returns (string memory str) {
        if (value == 0) {
            return "0";
        }
        
        uint256 temp = value;
        uint256 digits;
        
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}