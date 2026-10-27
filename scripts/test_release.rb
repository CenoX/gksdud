require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require_relative 'release-metadata'
require_relative 'resolve-release'

class ReleaseTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_tag_must_match_numeric_app_version
    %w[main v1.2.1 pre-v1.2.0 canary-v1.2.0 v.1.2.0 1.2.0 v1.2.0-beta.1 ../1.2.0].each do |tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new('1.2.0', tag) }
    end
    # Every tag is vVERSION; stable releases have three fields, prereleases four with the fourth from 1, canary releases five
    # with the fifth from 1.
    assert_equal %w[stable pre canary canary], %w[1.2.0 1.2.0.1 1.2.0.1.3 1.2.1.0.1].map { |version| ReleaseMetadata.new(version).channel }
    [%w[1.2.0.1 pre-v1.2.0.1], %w[1.2.0.1.3 canary-v1.2.0.1.3], %w[1.2.0.0 v1.2.0.0], %w[1.2.0.01 v1.2.0.01], %w[1.2.0.1.0 v1.2.0.1.0],
     %w[1.2.0.1.1.1 v1.2.0.1.1.1]].each do |version, tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version, tag) }
    end
    ["1.2.0\n", '1.2', '1.2.0-beta.1', '01.2.0', '1.02.0', '1.2.00'].each do |version|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version) }
    end
  end

  def test_stable_and_prerelease_assets_are_separate
    stable = ReleaseMetadata.new('1.2.0', 'v1.2.0')
    pre = ReleaseMetadata.new('1.2.0.1', 'v1.2.0.1')
    canary = ReleaseMetadata.new('1.2.0.1.3', 'v1.2.0.1.3')
    refute stable.prerelease?
    assert pre.prerelease?
    assert canary.prerelease?
    assert_equal 'gksdud-1.2.0.zip', stable.filename
    # The name an app takes for the version it updates to.
    assert_equal 'gksdud-1.2.0.1.zip', pre.filename
    assert_equal 'gksdud-1.2.0.1.3.zip', canary.filename
    # The fork's 1.3.2 updater downloads the same notarized app under the old name.
    refute ReleaseMetadata::SELF_SIGNED_COPY
    assert_nil stable.self_signed_filename
    assert_equal 'gksdud-1.2.0-macos-universal.zip', stable.legacy_filename
    assert_nil canary.self_signed_filename
    assert_nil pre.self_signed_filename
    # One app for every channel.
    assert_equal %w[gksdud gksdud gksdud], [stable, pre, canary].map(&:app)
    assert_equal ['io.gksdud.inputswitch'], [stable, pre, canary].map(&:identifier).uniq
    assert_equal 3, [stable, pre, canary].map(&:asset_version).uniq.length
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
    with_release_repository do |selection, command, _|
      # Only a prerelease goes out from its tag; stable releases are manual and canary ones come from main.
      %w[v1.2.0 v1.2.0.0.1 pre-v1.2.0.1 canary-v1.2.0.0.1].each do |tag|
        error = assert_raises(RuntimeError) { selection.resolve(event: 'push', tag: tag, version: '', source: '', summary: '') }
        assert_includes error.message, 'Only a prerelease'
      end
      # A prerelease's version is its tag's, after the source's stable version, which must be out already.
      error = assert_raises(RuntimeError) { selection.resolve(event: 'push', tag: 'v1.2.0.1', version: '', source: '', summary: '') }
      assert_match 'v1.2.0 does not exist', error.message
      command.call('git', 'tag', 'v1.2.0')
      result = selection.resolve(event: 'push', tag: 'v1.2.0.1', version: '', source: '', summary: '')
      assert_equal ['1.2.0.1', 'v1.2.0.1', 'pre', true], result.values_at(:version, :tag, :channel, :prerelease)
      assert_raises(ArgumentError) { selection.resolve(event: 'push', tag: 'v1.2.0.0', version: '', source: '', summary: '') }
      # A manual release is stable.
      %w[1.3.0.1 1.3.0.0.1].each do |version|
        assert_raises(ArgumentError) { selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input') }
      end
    end
  end

  def test_a_push_to_main_numbers_its_canary_after_the_latest_prerelease_or_stable_release
    with_release_repository do |selection, git, dir|
      push = { event: 'push', tag: 'main', version: '', source: '', summary: '', branch: true }
      commit = ->(subject) { git.call('git', 'commit', '--allow-empty', '-m', subject) }
      commit.call('Second')
      error = assert_raises(RuntimeError) { selection.resolve(**push) }
      assert_includes error.message, 'No prerelease or stable release tag'
      git.call('git', 'tag', 'v1.2.0', 'HEAD~1')
      git.call('git', 'tag', 'v1.1.9', 'HEAD~1')
      git.call('git', 'tag', 'pre-v1.5.0.1')
      commit.call('Change')
      result = selection.resolve(**push)
      assert_equal ['1.2.0.0.2', 'v1.2.0.0.2', 'canary', true], result.values_at(:version, :tag, :channel, :prerelease)
      assert_equal git.call('git', 'rev-parse', 'HEAD'), result.fetch(:source_sha)
      assert_equal 'gksdud-1.2.0.0.2.zip', result.fetch(:filename)
      # A prerelease, or a stable release, of the same commit leaves the number of a rerun alone.
      git.call('git', 'tag', '-a', '-m', 'Prerelease', 'v1.2.0.1')
      assert_equal '1.2.0.0.2', selection.resolve(**push).fetch(:version)
      commit.call('After the prerelease')
      assert_equal '1.2.0.1.1', selection.resolve(**push).fetch(:version)
      # A prerelease off this branch is not before the commit.
      git.call('git', 'tag', 'v1.2.0.9', git.call('git', 'commit-tree', '-m', 'Elsewhere', 'HEAD^{tree}'))
      git.call('git', 'tag', 'v1.2.0.1.1', 'HEAD')
      commit.call('Next')
      assert_equal '1.2.0.1.2', selection.resolve(**push).fetch(:version)
      git.call('git', 'tag', 'v1.2.1', 'HEAD~1')
      assert_equal '1.2.1.0.1', selection.resolve(**push).fetch(:version)
      # A prerelease pushed before its stable release is refused and does not count.
      git.call('git', 'tag', 'v1.3.0.1', 'HEAD~1')
      assert_equal '1.2.1.0.1', selection.resolve(**push).fetch(:version)
      git.call('git', 'tag', 'v1.3.0', 'HEAD~1')
      assert_equal '1.3.0.1.1', selection.resolve(**push).fetch(:version)
      # A local build numbers itself the same way.
      FileUtils.cp("#{ROOT}/build.sh", "#{dir}/build.sh")
      script = File.read("#{ROOT}/build.sh")[/^if \[\[ \$channel != stable.*?^fi$/m]
      output, = Open3.capture2e({ 'channel' => 'dev' }, '/bin/bash', '-c', "set -euo pipefail\n#{script}\necho \"$GKSDUD_APP_VERSION\"", chdir: dir)
      assert_equal '1.3.0.1.1', output.strip
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

  # Exercise manual publication against a fake gh; nothing reaches GitHub.
  def publication_result(draft: true, prerelease: false, actual_tag: 'v1.2.0', summary: 'Input fixes', warning: '', latest: 'true', view_exit: 0, edit_exit: 0)
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
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'RELEASE_SUMMARY' => summary, 'RELEASE_WARNING' => warning, 'MAKE_LATEST' => latest,
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
    assert_includes notes, 'Developer ID'
    refute_includes notes, '### 경고'
  end

  def test_publish_can_leave_the_latest_release_alone
    status, args, _, output = publication_result(latest: 'false')
    assert status.success?, output
    assert_equal ['--draft=false', '--latest=false'], args.last(2)
  end

  def test_publish_adds_the_warning_section_after_the_summary
    status, _, notes, output = publication_result(summary: '- 서명 변경', warning: " - 손쉬운 사용 권한을 다시 허용\n")
    assert status.success?, output
    assert_includes notes, "### 요약\n\n- 서명 변경\n\n### 경고\n\n- 손쉬운 사용 권한을 다시 허용\n\n### 설치"
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
