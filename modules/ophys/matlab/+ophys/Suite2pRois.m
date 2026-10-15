classdef Suite2pRois < nansen.FileAdapter
%Suite2pRois suite2p's cells: stat (each cell's 0-based ypix and xpix), iscell and ops (Ly, Lx)
%
%   From its Fall.mat, or from its output folder of .npy files as dev's
%   Suite2p ROI converter collects them: stat.npy, with iscell.npy and
%   ops.npy beside it. A folder is a plane's (it has stat.npy), or
%   suite2p's output folder (or one holding it, suite2p/) of plane0,
%   plane1, ...: all its planes, each cell with its plane (planeN is plane
%   N + 1) and channel 1. stat.npy is a pickled array of dicts, read
%   without Python by ophys.internal.readPickledNpy, which runs nothing in
%   it (dev converted it with Python); Ly and Lx are found in ops.npy's
%   bytes, as Suite2pBinary finds them. Read as the module's ROI document;
%   cells suite2p's classifier leaves out (iscell 0) are classified
%   rejected. Read only. Python's ophys_adapters.Suite2pRois reads the same.

    methods
        function data = read(~, path)
            path = string(path);
            if isfolder(path)
                data = ophys.Suite2pRois.readFolder(path);
                return
            end
            [~, ~, extension] = fileparts(path);
            if lower(extension) == ".npy"
                [imageSize, lists, labels] = ophys.Suite2pRois.readPlane(path);
                data = ophys.internal.roiDocument(imageSize, lists, labels);
                return
            end
            contents = load(path);
            if ~isfield(contents, "stat") || ~isfield(contents, "ops")
                nansen.internal.throwError("invalid-data", "%s is not suite2p's Fall.mat (no stat or ops)", path)
            end
            stat = contents.stat;
            if isstruct(stat)
                stat = num2cell(stat);
            end
            iscell_ = [];
            if isfield(contents, "iscell")
                iscell_ = double(contents.iscell);
            end
            [lists, labels] = ophys.Suite2pRois.cells(stat, iscell_);
            data = ophys.internal.roiDocument([contents.ops.Ly, contents.ops.Lx], lists, labels);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "suite2p's files are written by suite2p; ROIs are saved as JSON")
        end
    end

    methods (Static, Access = private)
        function [lists, labels] = cells(stat, iscell_)
            % Each cell's 0-based [row, column] pixels, and "rejected" where iscell's first column is 0
            if isempty(iscell_)
                iscell_ = ones(numel(stat), 1);
            end
            lists = cell(1, numel(stat));
            labels = repmat({""}, 1, numel(stat));
            for k = 1:numel(stat)
                if ~isstruct(stat{k}) || ~isfield(stat{k}, "ypix") || ~isfield(stat{k}, "xpix")
                    nansen.internal.throwError("invalid-data", "suite2p's stat has no ypix and xpix for cell %d", k)
                end
                lists{k} = [double(stat{k}.ypix(:)), double(stat{k}.xpix(:))];
                if k <= size(iscell_, 1) && iscell_(k, 1) == 0
                    labels{k} = "rejected";
                end
            end
        end

        function [imageSize, lists, labels] = readPlane(path)
            % A plane's stat.npy, with the iscell.npy (if any) and ops.npy beside it
            folder = fileparts(path);
            ops = fullfile(folder, "ops.npy");
            if ~isfile(ops)
                nansen.internal.throwError("invalid-data", "%s: there is no ops.npy beside it, which has the image size", path)
            end
            stat = ophys.internal.readPickledNpy(path);
            if ~iscell(stat)
                nansen.internal.throwError("invalid-data", "%s is not suite2p's stat (an array of each cell's dict)", path)
            end
            iscell_ = [];
            if isfile(fullfile(folder, "iscell.npy"))
                iscell_ = double(nansen.adapters.Npy().read(fullfile(folder, "iscell.npy")));
            end
            [lists, labels] = ophys.Suite2pRois.cells(stat(:)', iscell_);
            fid = fopen(ops, "r");
            bytes = fread(fid, Inf, "*uint8")';
            fclose(fid);
            imageSize = [ophys.Suite2pBinary.pickledInt(bytes, "Ly", ops), ophys.Suite2pBinary.pickledInt(bytes, "Lx", ops)];
        end

        function data = readFolder(folder)
            if isfile(fullfile(folder, "stat.npy"))
                [imageSize, lists, labels] = ophys.Suite2pRois.readPlane(fullfile(folder, "stat.npy"));
                data = ophys.internal.roiDocument(imageSize, lists, labels);
                return
            end
            [numbers, planes] = ophys.Suite2pRois.planeFolders(folder);
            if isempty(planes) && isfolder(fullfile(folder, "suite2p"))
                folder = fullfile(folder, "suite2p");
                [numbers, planes] = ophys.Suite2pRois.planeFolders(folder);
            end
            if isempty(planes)
                nansen.internal.throwError("invalid-data", "%s has no stat.npy, nor suite2p's plane folders with one", folder)
            end
            imageSize = [];
            lists = {};
            labels = {};
            places = zeros(0, 2);
            for p = 1:numel(planes)
                [planeSize, planeLists, planeLabels] = ophys.Suite2pRois.readPlane(fullfile(planes(p), "stat.npy"));
                if isempty(imageSize)
                    imageSize = planeSize;
                end
                lists = [lists, planeLists]; %#ok<AGROW>
                labels = [labels, planeLabels]; %#ok<AGROW>
                places = [places; repmat([numbers(p) + 1, 1], numel(planeLists), 1)]; %#ok<AGROW>
            end
            data = ophys.internal.roiDocument(imageSize, lists, labels, places);
        end

        function [numbers, planes] = planeFolders(folder)
            % suite2p's plane folders (planeN) with a stat.npy, in the order of N
            listing = dir(folder);
            listing = listing([listing.isdir]);
            numbers = zeros(1, 0);
            planes = strings(1, 0);
            for k = 1:numel(listing)
                token = regexp(listing(k).name, "^plane(\d+)$", "tokens", "once");
                if ~isempty(token) && isfile(fullfile(folder, listing(k).name, "stat.npy"))
                    numbers(end + 1) = str2double(token{1}); %#ok<AGROW>
                    planes(end + 1) = string(fullfile(folder, listing(k).name)); %#ok<AGROW>
                end
            end
            [numbers, order] = sort(numbers);
            planes = planes(order);
        end
    end
end
