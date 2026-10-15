classdef Suite2pRois < nansen.FileAdapter
%Suite2pRois suite2p's Fall.mat: stat (each cell's 0-based ypix and xpix), iscell and ops (Ly, Lx)
%
%   Read as the module's ROI document; cells suite2p's classifier leaves
%   out (iscell 0) are classified rejected. Read only. Python's
%   ophys_adapters.Suite2pRois reads the same.

    methods
        function data = read(~, path)
            contents = load(path);
            if ~isfield(contents, "stat") || ~isfield(contents, "ops")
                nansen.internal.throwError("invalid-data", "%s is not suite2p's Fall.mat (no stat or ops)", path)
            end
            stat = contents.stat;
            if isstruct(stat)
                stat = num2cell(stat);
            end
            iscell_ = ones(numel(stat), 1);
            if isfield(contents, "iscell")
                iscell_ = double(contents.iscell);
            end
            lists = cell(1, numel(stat));
            labels = repmat({""}, 1, numel(stat));
            for k = 1:numel(stat)
                lists{k} = [double(stat{k}.ypix(:)), double(stat{k}.xpix(:))];
                if k <= size(iscell_, 1) && iscell_(k, 1) == 0
                    labels{k} = "rejected";
                end
            end
            data = ophys.internal.roiDocument([contents.ops.Ly, contents.ops.Lx], lists, labels);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "suite2p's files are written by suite2p; ROIs are saved as JSON")
        end
    end
end
