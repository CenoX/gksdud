require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'open3'
require_relative 'release-metadata'
require_relative 'resolve-release'

class ReleaseTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_tag_must_match_numeric_app_version
    %w[main v1.2.1 pre-v.1.2.1 pre-v1.2.1 pre-v1.2.0-beta.1 pre-v.1.2.0-beta.1 ../1.2.0].each do |tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new('1.2.0', tag) }
    end
    ["1.2.0\n", '1.2', '1.2.0-beta.1', '01.2.0', '1.02.0', '1.2.00'].each do |version|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version) }
    end
  end

  def test_stable_and_prerelease_assets_are_separate
    stable = ReleaseMetadata.new('1.2.0', 'v1.2.0')
    pre = ReleaseMetadata.new('1.2.0', 'pre-v1.2.0')
    refute stable.prerelease?
    assert pre.prerelease?
    assert_equal 'gksdud-1.2.0-macos-universal.zip', stable.filename
    assert_equal 'gksdud-1.2.0-pre-macos-universal.zip', pre.filename
    refute_equal stable.asset_version, pre.asset_version
    legacy = ReleaseMetadata.new('1.2.0', 'pre-v.1.2.0')
    assert legacy.prerelease?
    assert_equal pre.filename, legacy.filename
  end

  def with_release_repository
    Dir.mktmpdir('gksdud-source-test-') do |dir|
      command = lambda do |*args|
        output, status = Open3.capture2e(*args, chdir: dir)
        assert status.success?, output
        output.strip
      end
      command.call('git', 'init', '-b', 'main')
      command.call('git', 'config', 'user.name', 'Release Test')
      command.call('git', 'config', 'user.email', 'test@example.invalid')
      File.write("#{dir}/Info.plist", '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.0</string></dict></plist>')
      command.call('git', 'add', 'Info.plist')
      command.call('git', 'commit', '-m', 'Initial source')
      command.call('git', 'remote', 'add', 'origin', dir)
      yield ReleaseSelection.new(dir), command, dir
    end
  end

  def test_pushed_tags_must_match_source_version
    with_release_repository do |selection, _, _|
      %w[v1.2.0 pre-v1.2.0 pre-v.1.2.0].each do |tag|
        result = selection.resolve(event: 'push', tag: tag, version: '', source: '', summary: '')
        assert_equal '1.2.0', result.fetch(:version)
        assert_equal tag.start_with?('pre-v'), result.fetch(:prerelease)
      end
      assert_raises(ArgumentError) { selection.resolve(event: 'push', tag: 'v9.0.0', version: '', source: '', summary: '') }
    end
  end

  def test_manual_release_pins_branch_or_commit_and_does_not_create_tags
    with_release_repository do |selection, git, dir|
      sha = git.call('git', 'rev-parse', 'HEAD')
      %W[main #{sha}].each do |source|
        result = selection.resolve(event: 'workflow_dispatch', tag: '', version: '1.3.0', source: source, summary: 'Fix input')
        assert_equal sha, result.fetch(:source_sha)
        assert_equal 'v1.3.0', result.fetch(:tag)
        assert_equal false, result.fetch(:tag_exists)
      end
      assert_empty git.call('git', 'tag', '--list')
      assert_includes File.read("#{dir}/Info.plist"), '<string>1.2.0</string>'
      File.write("#{dir}/next", 'next source')
      git.call('git', 'add', 'next')
      git.call('git', 'commit', '-m', 'Move branch')
      result = selection.resolve(event: 'workflow_dispatch', tag: '', version: '1.3.0', source: sha, summary: 'Pinned release')
      assert_equal sha, result.fetch(:source_sha)
    end
  end

  def test_existing_lightweight_and_annotated_tags_are_never_retargeted
    with_release_repository do |selection, git, dir|
      %w[lightweight annotated].each_with_index do |kind, index|
        version = "1.3.#{index}"
        args = ['git', 'tag']
        args += ['-a', '-m', 'Release'] if kind == 'annotated'
        git.call(*args, "v#{version}")
        result = selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input')
        assert_equal true, result.fetch(:tag_exists)
      end
      File.write("#{dir}/next", 'different source')
      git.call('git', 'add', 'next')
      git.call('git', 'commit', '-m', 'Change source')
      %w[1.3.0 1.3.1].each do |version|
        error = assert_raises(RuntimeError) { selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input') }
        assert_includes error.message, 'different commit'
      end
    end
  end

  def test_manual_release_rejects_missing_summary_bad_version_or_source
    with_release_repository do |selection, _, _|
      base = { event: 'workflow_dispatch', tag: '', version: '1.3.0', source: 'main', summary: 'Fix input' }
      [{ summary: '' }, { version: '1.03.0' }, { source: '--upload-pack=nope' }, { source: 'missing' }].each do |change|
        assert_raises(StandardError) { selection.resolve(**base.merge(change)) }
      end
    end
  end

  def publication_result(draft: true, prerelease: false, actual_tag: 'v1.2.0', summary: 'Input fixes', view_exit: 0, edit_exit: 0)
    Dir.mktmpdir('gksdud-publish-test-') do |dir|
      File.write("#{dir}/gh", <<~RUBY)
        #!/usr/bin/ruby
        require 'json'
        if ARGV.first(2) == ['release', 'view']
          puts ENV.fetch('RELEASE_JSON')
          exit ENV.fetch('VIEW_EXIT').to_i
        end
        File.write(ENV.fetch('CAPTURE'), JSON.generate(ARGV))
        File.write(ENV.fetch('NOTES'), File.read(ARGV.fetch(ARGV.index('--notes-file') + 1)))
        exit ENV.fetch('EDIT_EXIT').to_i
      RUBY
      File.chmod(0755, "#{dir}/gh")
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'RELEASE_SUMMARY' => summary,
              'RELEASE_JSON' => JSON.generate(tagName: actual_tag, isDraft: draft, isPrerelease: prerelease),
              'CAPTURE' => "#{dir}/args.json", 'NOTES' => "#{dir}/notes.md",
              'VIEW_EXIT' => view_exit.to_s, 'EDIT_EXIT' => edit_exit.to_s }
      output, status = Open3.capture2e(env, '/usr/bin/ruby', "#{ROOT}/scripts/publish-release.rb", 'CenoX/gksdud', 'v1.2.0')
      args = File.exist?("#{dir}/args.json") ? JSON.parse(File.read("#{dir}/args.json")) : nil
      notes = File.exist?("#{dir}/notes.md") ? File.read("#{dir}/notes.md") : nil
      [status, args, notes, output]
    end
  end

  def test_publish_uses_literal_summary_and_never_uploads_assets
    summary = "- Option+` fix\n- Literal $(touch nope) \\1 text"
    status, args, notes, output = publication_result(summary: summary)
    assert status.success?, output
    assert_equal ['release', 'edit', 'v1.2.0', '--repo', 'CenoX/gksdud', '--notes-file'], args.first(6)
    assert_equal ['--draft=false', '--latest'], args.last(2)
    assert_equal 9, args.length
    assert_includes notes, summary
    refute_includes notes, '<!-- 게시 전'
    assert_includes notes, 'Developer ID로 서명하고 Apple 공증을 받은 빌드입니다.'
    refute_includes notes, 'brew install --cask codingnoye/tap/gksdud'
  end

  def test_published_release_is_not_edited_on_retry
    status, args, notes, output = publication_result(draft: false)
    assert status.success?, output
    assert_nil args
    assert_nil notes
  end

  def test_publication_rejects_invalid_release_missing_summary_and_failed_lookup
    [{ prerelease: true }, { actual_tag: 'v1.2.1' }, { summary: " \n" }, { view_exit: 1 }].each do |options|
      status, args, notes, = publication_result(**options)
      refute status.success?, options.inspect
      assert_nil args
      assert_nil notes
    end
    status, = publication_result(edit_exit: 1)
    refute status.success?
  end
end
