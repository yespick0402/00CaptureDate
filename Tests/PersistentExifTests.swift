import Foundation

@main
struct PersistentExifTests {
    static func main() throws {
        func verify(_ value: Bool, _ label: String) { if !value { fputs("FAIL: \(label)\n", stderr); exit(1) } }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("00CaptureDate-PersistentExif-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let script = temp.appendingPathComponent("exiftool")
        // Fake read-only exiftool CLI to test exact stay_open framing and fallback.
        let perl = #"""
        use strict; use warnings; use JSON::PP;
        $|=1;
        my $record = './launches.txt';
        open(my $fh, '>>', $record) or die $!; print $fh "launch\n"; close($fh);
        my $isOpen = grep { $_ eq '-stay_open' } @ARGV;
        my @args = ();
        sub respond {
          my ($id, $args) = @_;
          my @files = grep { $_ =~ m{^/} && $_ !~ m{^/usr/} } @$args;
          my @records = map {{ SourceFile => $_, 'ExifIFD:DateTimeOriginal' => '2026:11:21 09:07:05' }} @files;
          print JSON::PP->new->encode(\@records) . "\n";
          print "{ready$id}\n" if defined $id;
        }
        if ($isOpen) {
          while (my $line = <STDIN>) {
            $line =~ s/\r?\n$//;
            last if $line eq 'False';
            if ($line =~ /^-execute(\d+)$/) { respond($1, \@args); @args = (); }
            else { push @args, $line; }
          }
        } else { respond(undef, \@ARGV); }
        """#
        try perl.write(to: script, atomically: true, encoding: .utf8)
        let a = temp.appendingPathComponent("first.ARW")
        let b = temp.appendingPathComponent("second.HIF")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        func input(_ file: URL) -> MediaInput {
            MediaInput(url: file, size: 1, relativeFolder: "", modified: nil)
        }
        let session = PersistentExifSession(reader: MetadataReader(toolURL: script))
        let first = session.readBatch([input(a)])
        let second = session.readBatch([input(b)])
        verify(first[a.path]?.confidence == .high, "ARW classified using original decoder")
        verify(second[b.path]?.confidence == .high, "HIF classified using original decoder")
        session.close()
        // Startup counter: one process for both requests.
        let launches = try String(contentsOf: temp.appendingPathComponent("launches.txt"), encoding: .utf8)
        verify(launches.split(separator: "\n").count == 1, "ExifTool process reuses one launch")
        print("PASS: persistent ExifTool transport / numbered ready / ARW-HIF decoder unchanged / one process")
    }
}
