function [count, reader, first] = tiffPages(paths)
%tiffPages The pages of TIFF files as one sequence: how many, a reader of pages a..b (1-based) as height x
%width x n, and the first page's Tiff tags (Software, ImageDescription, Artist)
    warning("off", "imageio:tiffmexutils:libtiffWarning");
    warning("off", "MATLAB:imagesci:tiffmexutils:libtiffWarning");
    paths = reshape(string(paths), 1, []);
    counts = zeros(1, numel(paths));
    for i = 1:numel(paths)
        try
            file = Tiff(char(paths(i)), "r");
        catch error
            nansen.internal.throwError("invalid-data", "%s is not a TIFF file: %s", paths(i), error.message)
        end
        if i == 1
            first = struct("Software", tag(file, "Software"), "ImageDescription", tag(file, "ImageDescription"), ...
                "Artist", tag(file, "Artist"), "Page", file.read());
        else
            page = file.read();
            if ~isequal(size(page), size(first.Page)) || ~strcmp(class(page), class(first.Page))
                close(file);
                nansen.internal.throwError("invalid-data", "the files of a recording differ: %s has %s %s pages, %s %s %s", ...
                    paths(1), mat2str(size(first.Page)), class(first.Page), paths(i), mat2str(size(page)), class(page))
            end
        end
        n = 1;
        while ~file.lastDirectory()
            file.nextDirectory();
            n = n + 1;
        end
        close(file);
        counts(i) = n;
    end
    if ~ismatrix(first.Page)
        nansen.internal.throwError("invalid-data", "%s does not hold grayscale pages", paths(1))
    end
    offsets = [0, cumsum(counts)];
    count = offsets(end);
    reader = @(a, b) readPages(paths, offsets, first.Page, a, b);
end

function data = readPages(paths, offsets, page, a, b)
    data = zeros([size(page), b - a + 1], "like", page);
    k = 0;
    for i = 1:numel(paths)
        low = max(a, offsets(i) + 1);
        high = min(b, offsets(i + 1));
        if low > high
            continue
        end
        file = Tiff(char(paths(i)), "r");
        closer = onCleanup(@() close(file));
        file.setDirectory(low - offsets(i));
        for p = low:high
            if p > low
                file.nextDirectory();
            end
            k = k + 1;
            data(:, :, k) = file.read();
        end
        clear closer
    end
end

function value = tag(file, name)
    try
        value = string(file.getTag(char(name)));
    catch
        value = "";
    end
end
