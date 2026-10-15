"""A file adapter to import: a .thing file is a line of text, read as its words."""


class ThingReader:
    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read().split()

    def write(self, path, data):
        with open(path, "w", encoding="utf-8") as f:
            f.write(" ".join(data))
