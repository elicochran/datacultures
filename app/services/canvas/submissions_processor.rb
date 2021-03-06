class Canvas::SubmissionsProcessor

  attr_accessor  :submission_conf, :request_object

  require 'array_refinement'
  using ArrayRefinement

  def initialize(conf)
    @submission_conf = PointsConfiguration.where({interaction: 'Submission'}).first
    @request_object     = conf[:request_object] || ApiRequest.new(api_key: conf['api_key'], base_url: conf['base_url'])
  end

  def call(submissions)

    ## rewrite for return data from assignments API call
    scoring_submissions = Activity.where({reason: 'Submission'}).select(:scoring_item_id, :canvas_user_id)
    if scoring_submissions
      scored_submissions = scoring_submissions.map{|s| [s.scoring_item_id, s.canvas_user_id] }
    else
      scored_submissions = []
    end

    canvas_student_ids = Student.all.map(&:canvas_user_id)
    attachment_processor = Canvas::AttachmentsProcessor.new({})

    submissions.each do |submission|
      user_id    = submission['user_id']
      assignment_id = submission['assignment_id']
      attachment_data = []
      url = submission['url']
      submitted_at = submission['submitted_at']
      has_url = (url && !url.empty?)
      attachments = submission['attachments']
      # Student::create_by_canvas_user_id is safe, but why do the extra SQL query every time?
      if !canvas_student_ids.include?(user_id.to_i)
        Student.create_by_canvas_user_id(user_id)
      end
      if has_url
        rendered_attachment = attachments.extract_rendering_attachments! if attachments
        if url =~ video_url_regexp
          previous_record = MediaUrl.where({canvas_assignment_id: assignment_id, canvas_user_id: user_id }).first
          if needs_video_processing?(url: url, submitted_at: submitted_at, previous_record: previous_record )
            ProcessMediaUrlWorker.perform_async(url, user_id, assignment_id, submission['submitted_at'])
          end
        else
          # NOOP for now; process non-YT/Vimeo URLs (CYB-321)
        end
      elsif attachments && !attachments.empty?
        previously_credited = Activity.where({scoring_item_id: submission['assignment_id'].to_s,
                                              reason: 'Submission', canvas_user_id: submission['user_id']}).first
        process_attachments(attachment_processor: attachment_processor, attachments: attachments,
                            submission: submission, previously_credited: previously_credited)
      end


      if user_id   && !(scored_submissions.include?([assignment_id.to_s, user_id]))
        Activity.score!({scoring_item_id: assignment_id,
                         canvas_user_id: user_id, reason: 'Submission',
                         body: attachment_data.to_json,
                         score: submission_conf.active, delta: submission_conf.points_associated,
                         canvas_updated_at: submission['submitted_at'] })
      end
    end

  end

  def process_attachments(attachment_processor:, attachments:, submission:, previously_credited:)
    ## Attachments on a submission are processed in two cases:
    #     1. It has not been done before for this student and this assignment, or
    #     2. The assignment has been resubmitted (the date is after the already credited date)
    if needs_processing?(previously_credited, submission['submitted_at'])
      attachment_processor.attachment_conf = {content_type: submission['content-type'], canvas_user_id: submission['user_id'],
                                              assignment_id: submission['assignment_id'], submission_id: submission['id'] }
      attachment_processor.call(attachments)
      if previously_credited
        previously_credited.update_attribute(:canvas_updated_at, submission['submitted_at'])
      end
    end
  end

  def needs_video_processing?(url: , submitted_at:, previous_record:)
    ## TODO: below compares a date in string format with one in ActiveSupport::TimeWithZone
    ## FIXME change one or the other for the comparison
    previous_record.nil? ||  !(submitted_at && previous_record.submitted_at && (Time.parse(submitted_at) == previous_record.submitted_at.to_time))
  end

  def video_url_regexp
    /\Ahttps:\/\/www\.youtube\.com|\Ahttp:\/\/youtu\.be|www\.youtube.com\/embed|\Ahttp:\/\/vimeo\.com|player\.vimeo\.com\/video/
  end

  def needs_processing?(previously_credited, new_date)
    previously_credited.nil? || (previously_credited.canvas_updated_at.to_time != Time.parse(new_date))
  end

end
