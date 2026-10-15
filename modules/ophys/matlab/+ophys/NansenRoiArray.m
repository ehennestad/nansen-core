classdef NansenRoiArray < nansen.FileAdapter
%NansenRoiArray dev's ROI file (.mat): a struct array roiArray (or RoiArray, roi_arr) of RoI properties
%
%   As dev's roimanager saves it. Read as the module's ROI document: Mask
%   ROIs are their pixels, given as 1-based x (column), y (row); Circle
%   ROIs (x, y and a radius) are made into pixels as dev's RoI does; Polygon
%   ROIs are the pixels whose centre is inside, by the even-odd rule. Read
%   only. Python's ophys_adapters.NansenRoiArray reads the same.

    methods
        function data = read(~, path)
            contents = load(path);
            names = intersect(["roiArray", "RoiArray", "roi_arr"], string(fieldnames(contents)), "stable");
            if isempty(names)
                nansen.internal.throwError("invalid-data", "%s has no roiArray", path)
            end
            rois = contents.(names(1));
            if iscell(rois)
                rois = [rois{:}];
            end
            if isempty(rois)
                data = struct("imageSize", [0, 0], "rois", {{}});
                return
            end
            imageSize = double(rois(1).imagesize(:))';
            lists = cell(1, numel(rois));
            for k = 1:numel(rois)
                coordinates = double(rois(k).coordinates);
                switch string(rois(k).shape)
                    case "Circle"
                        lists{k} = ophys.NansenRoiArray.circlePixels(coordinates(1), coordinates(2), coordinates(3));
                    case "Polygon"
                        points = reshape(coordinates, [], 2);
                        [rows, columns] = ndgrid(0:imageSize(1) - 1, 0:imageSize(2) - 1);
                        candidates = sortrows([rows(:), columns(:)]);
                        keep = false(size(candidates, 1), 1);
                        for p = 1:size(candidates, 1)
                            keep(p) = ophys.internal.inPolygon(points(:, 1), points(:, 2), candidates(p, 2) + 1, candidates(p, 1) + 1);
                        end
                        lists{k} = candidates(keep, :);
                    otherwise   % Mask, IMask, Donut: 1-based x, y of each pixel
                        points = reshape(coordinates, [], size(coordinates, 2));
                        lists{k} = [round(points(:, 2)) - 1, round(points(:, 1)) - 1];
                end
            end
            data = ophys.internal.roiDocument(imageSize, lists);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "dev's ROI files are read here; ROIs are saved as JSON")
        end
    end

    methods (Static, Access = private)
        function pixels = circlePixels(x, y, r)
            % dev's RoI.getPixelIdxList for a circle: a local disk offset by the centre's fraction, placed at the centre
            [xx, yy] = meshgrid((-r:r) - mod(x, 1), (-r:r) - mod(y, 1));
            [X, Y] = find((xx .^ 2 + yy .^ 2) < r ^ 2);
            X = round(X + x - mean(X));
            Y = round(Y + y - mean(Y));
            pixels = [Y - 1, X - 1];   % dev indexes the image with (Y, X)
        end
    end
end
