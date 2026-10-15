classdef VhlabRois < nansen.FileAdapter
%VhlabRois dev's VHLab ROI files (.mat, as the VH lab's analyzetpstack saves them): cellstructs of cell outlines
%
%   Each cell's xi and yi are its outline (1-based x, y), read as dev's
%   dataconvert.roi.vhlab reads them: Polygon ROIs, the pixels whose
%   centre is inside by the even-odd rule (as NansenRoiArray's Polygon
%   ROIs), in a 512 x 512 image, the size dev gives them (the file has
%   none). Read as the module's ROI document. Read only. Python's
%   ophys_adapters.VhlabRois reads the same.

    properties (Constant)
        ImageSize = [512, 512]
    end

    methods
        function data = read(obj, path)
            contents = load(path);
            if ~isfield(contents, "cellstructs")
                nansen.internal.throwError("invalid-data", "%s has no cellstructs of VHLab's ROIs", path)
            end
            cells = contents.cellstructs;
            if iscell(cells)
                cells = [cells{:}];
            end
            if ~isempty(cells) && (~isstruct(cells) || ~all(isfield(cells, ["xi", "yi"])))
                nansen.internal.throwError("invalid-data", "%s: the cells of cellstructs have no xi and yi", path)
            end
            lists = cell(1, numel(cells));
            for k = 1:numel(cells)
                lists{k} = ophys.internal.polygonPixels(cells(k).xi, cells(k).yi, obj.ImageSize(1), obj.ImageSize(2));
            end
            data = ophys.internal.roiDocument(obj.ImageSize, lists);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "VHLab's ROI files are written by its own tools; ROIs are saved as JSON")
        end
    end
end
