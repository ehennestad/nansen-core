function writeFovImage(path, image)
%writeFovImage Write an image of a FOV inventory ({width, height, pixels}) as a 24-bit BMP file
%
%   nansen.legacy.writeFovImage(path, image) writes the rows from the
%   bottom, each pixel's blue, green and red, each row padded to a multiple
%   of 4 bytes, with a 54-byte header: the same bytes as Python's
%   nansen.fovinventory.bmp. pixels is base64 of the 8-bit red, green and
%   blue values, pixel after pixel, row after row from the top. The folder
%   is made when it is not there.
    width = double(image.width);
    height = double(image.height);
    pixels = matlab.net.base64decode(string(image.pixels));
    stride = 3 * width;
    if numel(pixels) ~= stride * height
        nansen.internal.throwError("invalid-data", "an image of %d x %d has %d bytes", width, height, numel(pixels))
    end
    rows = reshape(uint8(pixels), 3, width, height);   % colour, column, row
    rows = rows([3, 2, 1], :, end:-1:1);   % blue, green, red; from the bottom
    rows = reshape(rows, stride, height);
    rows = [rows; zeros(mod(4 - mod(stride, 4), 4), height, "uint8")];
    data = reshape(rows, 1, []);
    bytes = @(value, type) typecast(cast(value, type), "uint8");   % little-endian, as MATLAB runs on
    header = [uint8('BM'), bytes(54 + numel(data), "uint32"), zeros(1, 4, "uint8"), bytes(54, "uint32"), ...
        bytes(40, "uint32"), bytes(width, "int32"), bytes(height, "int32"), bytes(1, "uint16"), bytes(24, "uint16"), ...
        bytes(0, "uint32"), bytes(numel(data), "uint32"), bytes(2835, "int32"), bytes(2835, "int32"), zeros(1, 8, "uint8")];
    folder = fileparts(path);
    if strlength(folder) > 0 && ~isfolder(folder)
        mkdir(folder);
    end
    file = fopen(path, "w");
    if file < 0
        nansen.internal.throwError("file-not-found", "cannot write %s", path)
    end
    closer = onCleanup(@() fclose(file));
    fwrite(file, [header, data], "uint8");
end
