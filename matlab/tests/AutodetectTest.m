classdef AutodetectTest < matlab.unittest.TestCase
%AutodetectTest dev's roimanager autodetection modes (nansen.internal.autodetectRoi: rois.detect and view.detect mode)
%and the Mean CLAHE projection (nansen.internal.meanClahe) on a synthetic cell whose pixels are known, made without
%random numbers so that Python's test_autodetect makes the same recording and finds the same pixels.

    methods (Static)
        function [data, disk] = recording()
            % 40 x 40 x 60: a background of whole numbers that varies a little, and a round cell of radius 4 at row 21,
            % column 19 (1-based) with a darker nucleus within sqrt(5), active in every third frame
            [columns, rows] = meshgrid(1:40, 1:40);
            distance = (rows - 21) .^ 2 + (columns - 19) .^ 2;
            disk = distance <= 16;
            cell = double(disk) - 0.5 * double(distance <= 5);
            data = zeros(40, 40, 60);
            for t = 1:60
                data(:, :, t) = 100 + mod(rows * 7 + columns * 3 + t * 5, 5) + cell * (40 + 260 * (mod(t, 3) == 0));
            end
            data = uint16(data);
        end

        function mask = maskOf(pixels)
            mask = false(40, 40);
            for k = 1:size(pixels, 1)
                mask(pixels(k, 1) + 1, pixels(k, 2) + 1) = true;
            end
        end
    end

    methods (Test)
        function everyModeFindsTheCellAroundAClick(testCase)
            [data, disk] = AutodetectTest.recording();
            stack = nansen.Stack.fromArray(data, 3);
            near = conv2(double(disk), ones(5), "same") > 0;   % the disk grown by 2 pixels
            for mode = 1:5
                pixels = nansen.internal.autodetectRoi(stack, [20 18], 4, mode);
                testCase.verifyEqual(pixels, sortrows(pixels));   % row-major, 0-based
                mask = AutodetectTest.maskOf(pixels);
                testCase.verifyFalse(any(mask(:) & ~near(:)), sprintf("mode %d", mode));
                if mode == 1 || mode == 5   % flufinder's edge detection: the whole cell
                    testCase.verifyEqual(nnz(mask & disk), nnz(disk), sprintf("mode %d", mode));
                else   % thresholding after a 5 x 5 median filter: most of the cell
                    testCase.verifyGreaterThanOrEqual(nnz(mask & disk), 0.7 * nnz(disk), sprintf("mode %d", mode));
                end
            end
        end

        function theSamePixelsAsPythonFinds(testCase)
            % a count and the sum of row * 40 + column (0-based) per mode, 0-5, as Python's
            % test_the_same_pixels_as_matlab_finds: through the nucleus's edge too
            stack = nansen.Stack.fromArray(AutodetectTest.recording(), 3);
            signature = zeros(6, 2);
            for mode = 0:5
                pixels = nansen.internal.autodetectRoi(stack, [20 18], 4, mode);
                signature(mode + 1, :) = [size(pixels, 1), sum(pixels(:, 1) * 40 + pixels(:, 2))];
            end
            testCase.verifyEqual(signature, [1 777; 62 50800; 37 30266; 57 46626; 57 46626; 67 54806]);
            equalised = nansen.internal.meanClahe(stack);
            testCase.verifyEqual(sum(equalised(:)), 297239);
            testCase.verifyEqual(equalised(21, 11:16), [139 207 160 231 219 171]);
        end

        function badModesAndPointsAreRefused(testCase)
            stack = nansen.Stack.fromArray(AutodetectTest.recording(), 3);
            modes = {6, -1, "1", true, 1.5};
            for k = 1:numel(modes)
                testCase.verifyError(@() nansen.internal.autodetectRoi(stack, [20 18], 4, modes{k}), "nansen:InvalidParams");
            end
            testCase.verifyError(@() nansen.internal.autodetectRoi(stack, [40 0], 4, 1), "nansen:InvalidParams");
            pixels = nansen.internal.autodetectRoi(stack, [0 0], 4, 1);   % dev's box reaches past the image: 0 there
            testCase.verifyTrue(all(pixels(:) >= 0 & pixels(:) < 40));
        end

        function meanClaheIsTheNormalisedMeanWhenSmallAndTheMeanWhenFlat(testCase)
            data = AutodetectTest.recording();
            small = data(1:20, :, :);
            average = mean(double(small), 3);
            testCase.verifyEqual(nansen.internal.meanClahe(nansen.Stack.fromArray(small, 3)), ...
                (average - min(average(:))) / (max(average(:)) - min(average(:))), "AbsTol", 1e-12);
            flat = nansen.Stack.fromArray(repmat(uint16(9), 40, 40, 2), 3);
            testCase.verifyEqual(nansen.internal.meanClahe(flat), repmat(9, 40, 40));
            frame = nansen.internal.imageFrame(nansen.Stack.fromArray(data, 3), 0, 0, "meanClahe", []);
            testCase.verifyEmpty(frame.frame);
        end
    end
end
