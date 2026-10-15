classdef NansenRoiArray < nansen.FileAdapter
%NansenRoiArray dev's ROI file (.mat): a struct array roiArray (or RoiArray, roi_arr) of RoI properties
%
%   As dev's roimanager and RoiGroup adapter save it, with roiClassification
%   beside it (1 accepted, 2 rejected, 3 unresolved; 0 unclassified). Read as the module's ROI document: Mask and Donut
%   ROIs are their pixels, given as 1-based x (column), y (row); IMask ROIs
%   those of weight above 0; Circle ROIs (x, y and a radius) are made into
%   pixels as dev's RoI does; Polygon ROIs are the pixels whose centre is
%   inside, by the even-odd rule. A file of several planes or channels
%   (dev's RoiGroup: cells of them, planes x channels, with PlaneNumber and
%   ChannelNumber) is read whole, each ROI with its plane and channel.
%   Written as dev's RoiGroup adapter writes: Mask ROIs and their
%   classification, which dev reads, as cells of planes x channels when the
%   ROIs have places. Python's ophys_adapters.NansenRoiArray is the same.

    methods
        function data = read(~, path)
            contents = load(path);
            names = intersect(["roiArray", "RoiArray", "roi_arr"], string(fieldnames(contents)), "stable");
            if isempty(names)
                nansen.internal.throwError("invalid-data", "%s has no roiArray", path)
            end
            rois = contents.(names(1));
            classes = [];
            if isfield(contents, "roiClassification")
                classes = contents.roiClassification;
            end
            if ~iscell(rois)
                [imageSize, lists, labels, extras] = ophys.NansenRoiArray.group(rois, classes);
                data = ophys.NansenRoiArray.link(ophys.internal.roiDocument(imageSize, lists, labels, [], extras), extras);
                return
            end
            % dev's RoiGroup of several planes or channels (cells, planes x channels): every ROI, with its place
            imageSize = [];
            lists = {};
            labels = {};
            extras = {};
            places = zeros(0, 2);
            for g = 1:numel(rois)
                groupClasses = [];
                if iscell(classes) && numel(classes) == numel(rois)
                    groupClasses = classes{g};
                end
                [groupSize, groupLists, groupLabels, groupExtras] = ophys.NansenRoiArray.group(rois{g}, groupClasses);
                if isempty(imageSize)
                    imageSize = groupSize;
                end
                [plane, channel] = ind2sub(size(rois), g);
                plane = ophys.NansenRoiArray.number(contents, "PlaneNumber", g, numel(rois), plane);
                channel = ophys.NansenRoiArray.number(contents, "ChannelNumber", g, numel(rois), channel);
                lists = [lists, groupLists]; %#ok<AGROW>
                labels = [labels, groupLabels]; %#ok<AGROW>
                extras = [extras, groupExtras]; %#ok<AGROW>
                places = [places; repmat([plane, channel], numel(groupLists), 1)]; %#ok<AGROW>
            end
            if isempty(imageSize)
                imageSize = [0, 0];
            end
            data = ophys.NansenRoiArray.link(ophys.internal.roiDocument(imageSize, lists, labels, places, extras), extras);
        end

        function write(~, path, data)
            rois = ophys.internal.roiList(data);
            imageSize = double(reshape(nansen.internal.getField(data, "imageSize", [0, 0]), 1, []));
            placed = any(cellfun(@(r) isfield(r, "plane") || isfield(r, "channel"), rois));
            % every ROI's uid (its own, or a new one), by id: links are written as the uids of the ROIs linked
            ids = cellfun(@(r) double(nansen.internal.getField(r, "id", NaN)), rois);
            uids = strings(1, numel(rois));
            for k = 1:numel(rois)
                uids(k) = string(nansen.internal.getField(rois{k}, "uid", ""));
                if uids(k) == ""
                    uids(k) = ophys.NansenRoiArray.uid();
                end
            end
            contents = struct("roiImages", {[]}, "roiStats", {[]});
            if ~placed
                [contents.roiArray, contents.roiClassification] = ophys.NansenRoiArray.records(rois, imageSize, ids, uids);
            else   % dev's RoiGroup: cells of planes x channels
                planeOf = cellfun(@(r) double(nansen.internal.getField(r, "plane", 1)), rois);
                channelOf = cellfun(@(r) double(nansen.internal.getField(r, "channel", 1)), rois);
                planes = max(planeOf);
                channels = max(channelOf);
                contents.roiArray = cell(planes, channels);
                contents.roiClassification = cell(planes, channels);
                contents.PlaneNumber = cell(planes, channels);
                contents.ChannelNumber = cell(planes, channels);
                for p = 1:planes
                    for c = 1:channels
                        [contents.roiArray{p, c}, contents.roiClassification{p, c}] = ...
                            ophys.NansenRoiArray.records(rois(planeOf == p & channelOf == c), imageSize, ids, uids);
                        contents.PlaneNumber{p, c} = p;
                        contents.ChannelNumber{p, c} = c;
                    end
                end
            end
            save(path, "-struct", "contents");
        end
    end

    methods (Static, Access = private)
        function [imageSize, lists, labels, extras] = group(rois, classes)
            % One plane's ROIs as 0-based pixel lists, classifications and what else they say (uid, cell type, tags, the
            % uids they are connected with), and their image size ([] when there are none)
            imageSize = [];
            lists = {};
            labels = {};
            extras = {};
            if isempty(rois)
                return
            end
            codes = double(classes(:));
            if numel(codes) ~= numel(rois)
                codes = zeros(numel(rois), 1);   % as dev: a classification of the wrong size is reset
            end
            labels = repmat({""}, 1, numel(rois));
            labels(codes == 1) = {"accepted"};
            labels(codes == 2) = {"rejected"};
            labels(codes == 3) = {"unresolved"};
            imageSize = double(rois(1).imagesize(:))';
            lists = cell(1, numel(rois));
            extras = cell(1, numel(rois));
            for k = 1:numel(rois)
                extras{k} = struct("uid", ophys.NansenRoiArray.textOf(rois(k), "uid"), ...
                    "cellType", ophys.NansenRoiArray.textOf(rois(k), "celltype"), ...
                    "tags", {ophys.NansenRoiArray.textsOf(rois(k), "tags")}, ...
                    "connected", {ophys.NansenRoiArray.textsOf(rois(k), "connectedrois")});
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
                        if string(rois(k).shape) == "IMask" && isfield(rois, "pixelweights") && numel(rois(k).pixelweights) == size(points, 1)
                            points = points(double(rois(k).pixelweights(:)) > 0, :);
                        end
                        lists{k} = [round(points(:, 2)) - 1, round(points(:, 1)) - 1];
                end
            end
        end

        function value = number(contents, name, g, count, default)
            % The PlaneNumber or ChannelNumber of group g, or the default when the file has none for it
            value = default;
            if isfield(contents, name) && iscell(contents.(name)) && numel(contents.(name)) == count && ~isempty(contents.(name){g})
                value = double(contents.(name){g}(1));
            end
        end

        function [roiArray, codes] = records(rois, imageSize, ids, uids)
            % dev's roiArray of Mask ROIs and its roiClassification; ids and uids are of every ROI of the file
            fields = ["uid", "shape", "coordinates", "pixelweights", "imagesize", "boundary", "area", "center", ...
                "connectedrois", "group", "celltype", "structure", "layer", "tags", "enhancedImage"];
            roiArray = repmat(cell2struct(cell(numel(fields), 1), cellstr(fields), 1), 1, numel(rois));
            codes = zeros(numel(rois), 1);
            for k = 1:numel(rois)
                pixels = double(rois{k}.pixels);
                coordinates = [pixels(:, 2) + 1, pixels(:, 1) + 1];   % 1-based x, y
                roiArray(k).uid = char(uids(ids == double(nansen.internal.getField(rois{k}, "id", NaN))));
                roiArray(k).shape = 'Mask';
                roiArray(k).coordinates = coordinates;
                roiArray(k).pixelweights = [];
                roiArray(k).imagesize = imageSize;
                roiArray(k).boundary = {[NaN, NaN]};
                roiArray(k).area = size(pixels, 1);
                roiArray(k).center = mean(coordinates, 1);
                linked = {};
                links = nansen.internal.getField(rois{k}, "links", []);
                if iscell(links)
                    links = cell2mat(cellfun(@double, reshape(links, 1, []), UniformOutput=false));
                end
                for id = reshape(double(links), 1, [])
                    if any(ids == id)
                        linked{end + 1} = char(uids(ids == id)); %#ok<AGROW>
                    end
                end
                roiArray(k).connectedrois = linked;
                roiArray(k).group = [];
                roiArray(k).celltype = char(string(nansen.internal.getField(rois{k}, "cellType", "")));
                roiArray(k).structure = 'na';
                roiArray(k).layer = '';
                tags = nansen.internal.getField(rois{k}, "tags", {});
                roiArray(k).tags = reshape(cellstr(string(tags)), [], 1);
                roiArray(k).enhancedImage = [];
                switch string(nansen.internal.getField(rois{k}, "classification", ""))
                    case "accepted"
                        codes(k) = 1;
                    case "rejected"
                        codes(k) = 2;
                    case "unresolved"
                        codes(k) = 3;
                end
            end
        end

        function text = textOf(roi, name)
            % A text field of a dev RoI, as char ('' when it has none)
            text = '';
            if isfield(roi, name) && (ischar(roi.(name)) || isstring(roi.(name)))
                text = char(roi.(name));
            end
        end

        function texts = textsOf(roi, name)
            % A cell field of a dev RoI (tags, connectedrois) as a row cell of char; {} when empty
            texts = {};
            if isfield(roi, name) && iscell(roi.(name))
                texts = cellfun(@char, reshape(roi.(name), 1, []), UniformOutput=false);
                texts = texts(~cellfun(@isempty, texts));
            end
        end

        function data = link(data, extras)
            % links (ids) for dev's connectedrois (uids) of the ROIs read, in order
            uids = cellfun(@(e) string(e.uid), extras);
            for k = 1:numel(data.rois)
                linked = [];
                for u = string(extras{k}.connected)
                    at = find(uids == u & uids ~= "", 1);
                    if ~isempty(at)
                        linked(end + 1) = data.rois{at}.id; %#ok<AGROW>
                    end
                end
                if ~isempty(linked)
                    data.rois{k}.links = num2cell(sort(linked));
                end
            end
        end

        function text = uid()
            % A random UUID, as dev's RoI has
            hex = dec2hex(randi([0, 15], 1, 32))';
            text = sprintf('%s-%s-4%s-%s-%s', hex(1:8), hex(9:12), hex(14:16), hex(17:20), hex(21:32));
        end

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
