# Overiding the standard beanstalk-client Pool to ignore NotFoundErrors.
# In this application, those errors should only occur when using multiple beanstalkd instances,
#  when one instance does not have a tube, and others do.
module Beanstalk
  class Pool
    def call_wrap(c, *args, &block)
      self.last_conn = c
      c.send(*args, &block)
    rescue NotFoundError => ex
      puts "Ignoring NotFoundError: #{ex.class}: #{ex}"
      nil
    rescue UnexpectedResponse => ex
      raise ex
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE => ex
      self.remove(c)
      raise ex
    end

    def on_tube(tube, &block)
      response = nil
      connection_size = open_connections.size
      # Retry if the desired tube is not found
      # Randomly picking over double the connection size, should eventually find it...
      #  but a better algorithm would be nicer at some point...
      # Note, that with just 1 beanstalkd instance, this code should always return on the first send
      for i in 1..(connection_size*2)
        response = send_to_rand_conn(:on_tube, tube, &block)
        break if not response.nil?
      end
      response
    end
  end
end

module BeanstalkdView

  class Server < Sinatra::Base
    include BeanstalkdView::BeanstalkdUtils
    enable :sessions
    register Sinatra::Flash

    root = File.dirname(File.expand_path(__FILE__))
    set :root, root
    set :views,  "#{root}/views"
    if respond_to? :public_folder
          set :public_folder, "#{root}/resources"
        else
          set :public, "#{root}/resources"
        end
    set :static, true

    get "/" do
      begin
        @tubes = beanstalk.list_tubes
        @stats = beanstalk.stats
        @tube_set = tube_set(@tubes)
        chart_data = get_chart_data_hash(@tube_set)
        @total_jobs_data = chart_data["total_jobs_data"]
        @buried_jobs_data = chart_data["buried_jobs_data"] if chart_data["buried_jobs_data"]["items"].size > 0
        erb :index
      rescue Beanstalk::NotConnected => @error
        erb :error
      end
    end

    post "/add_job" do
      begin
        response = nil
        body = JSON.parse(params[:body])
        beanstalk.on_tube(params[:tube]) do |conn|
          response = conn.put([ params[:tube], body ].to_json, params[:priority].to_i, params[:delay].to_i, params[:ttr].to_i)
        end
        if response
          flash_message = "Added job #{response.inspect}"
          redirect url("/")
        else
          flash_message = "Error adding job"
          redirect url("/")
        end
      rescue Beanstalk::NotConnected => @error
        erb :error
      end
    end

    get "/tube/:tube" do
      begin
        @tube = params[:tube]
        @stats = beanstalk.stats_tube(@tube)
        erb :tube_stats
      rescue Beanstalk::NotConnected => @error
        erb :error
      end
    end

    get "/peek/:tube/:type" do
      content_type :json
      begin
        response = nil
        beanstalk.on_tube(params[:tube]) do |conn|
          if (params[:type]) == "ready"
            response = conn.peek_ready()
          elsif (params[:type]) == "delayed"
            response = conn.peek_delayed()
          else
            response = conn.peek_buried()
          end
        end
        if response
          ret_value = response.stats
          ret_value["body"] = response.body
          ret_value.to_json
        else
          { :error => "No job was found, or an error occurred while trying to peek at the next job."}.to_json
        end
      rescue Beanstalk::NotConnected => @error
        { :error => @error.to_s }.to_json
      end
    end

    get "/api/tubes" do
      get_all_tubes_data.to_json
    end

    get "/tubes" do
      tubes_stats = get_all_tubes_data

      @tubes = tubes_stats[:tubes]
      @stats = tubes_stats[:stats]
      @workers = tubes_stats[:workers]

      erb :tubes
    end

    get "/delete/:tube/:job_id" do
       begin
          response = nil
          beanstalk.on_tube(params[:tube]) do |conn|
            response = conn.delete(params[:job_id].to_i)
          end
          if response
            flash_message = "Deleted Job #{params[:job_id]}"
            redirect url("/tube/#{params[:tube]}")
          else
            flash_message = "Error deleting Job #{params[:job_id]}"
            redirect url("/tube/#{params[:tube]}")
          end
        rescue Beanstalk::NotConnected => @error
          erb :error
        end
    end

    post "/pause" do
      begin
        response = beanstalk.pause_tube(params[:tube], params[:delay].to_i)
        if response
          flash_message = "Paused #{params[:tube]}. No jobs will be reserved for #{params[:delay].to_i} seconds."
          redirect url("/tube/#{params[:tube]}")
        else
          flash_message = "Error pausing #{params[:tube]}."
          redirect url("/tube/#{params[:tube]}")
        end
      rescue NameError => @error
        flash_message = "The pause_tube method is currently not implemented by this version of beanstalk-client."
        redirect url("/tube/#{params[:tube]}")
      rescue Beanstalk::NotConnected => @error
        erb :error
      end
    end

    post "/kick" do
      begin
        response = nil
        beanstalk.on_tube(params[:tube]) do |conn|
          response = conn.kick(params[:bound].to_i)
        end
        if response
          flash_message = "Kicked #{params[:tube]} for #{response} jobs."
          redirect url("/tube/#{params[:tube]}")
        else
          flash_message = "Error kicking #{params[:tube]}."
          redirect url("/tube/#{params[:tube]}")
        end
      rescue Beanstalk::NotConnected => @error
        erb :error
      end
    end

    get "/peeks" do
      begin
        tubes_list = tube_set(beanstalk.list_tubes)

        @peeks = {}

        tubes_list.each do |tube|
          @peeks[tube] = {
            :ready => peek_tube(tube, :ready),
            :delayed => peek_tube(tube, :delayed)
          }
        end

        erb :peeks
      end
    end

    def peek_tube(name, type)
      begin
        beanstalk.on_tube(name) do |conn|
          conn.send("peek_#{type.to_s}")
        end
      rescue Beanstalk::NotConnected => ex
        ex.to_s
      end
    end

    def url_path(*path_parts)
      [ path_prefix, path_parts ].join("/").squeeze('/')
    end
    alias_method :u, :url_path

    def path_prefix
      request.env['SCRIPT_NAME']
    end

    def flash_message
      flash(:bs)[:beanstalkd_view_notice]
    end

    def flash_message=(msg)
      flash(:bs)[:beanstalkd_view_notice] = msg
    end

    def notice_message
      message = flash_message
      flash_message = ''
      message
    end

    private

    # Return the stats data in a format for the Bluff JS UI Charts
    def get_chart_data_hash(tube_set)
      chart_data = Hash.new
      chart_data["total_jobs_data"] = Hash.new
      chart_data["buried_jobs_data"] = Hash.new
      chart_data["total_jobs_data"]["items"] = Array.new
      chart_data["buried_jobs_data"]["items"] = Array.new
      tube_set.each do |tube|
        begin
          stats = beanstalk.stats_tube(tube)
          #total_jobs
          total_jobs = stats['total-jobs']
            if total_jobs > 0
            total_datum = Hash.new
            total_datum["label"] = tube
            total_datum["data"] = total_jobs
            chart_data["total_jobs_data"]["items"] << total_datum
          end
          #buried_jobs
          buried_jobs = stats['current-jobs-buried']
          if buried_jobs > 0
            buried_datum = Hash.new
            buried_datum["label"] = tube
            buried_datum["data"] = buried_jobs
            chart_data["buried_jobs_data"]["items"] << buried_datum
          end
        rescue Beanstalk::NotFoundError
          puts "Ignoring Beanstalk::NotFoundError for #{tube}"
        end
      end
      chart_data
    end

    def get_all_tubes_data
      tubes_list = tube_set(beanstalk.list_tubes)

      tubes = Hash[tubes_list.map { |tube| [tube, beanstalk.stats_tube(tube)] }]

      stats = beanstalk.stats

      workers = {
        :active => tubes.values.map { |tube| tube['current-jobs-reserved'].to_i }.reduce(:+),
        :total => stats['current-workers']
      }

      {
        :tubes => tubes,
        :stats => stats,
        :workers => workers
      }
    end

    # Return a Set of tube names
    def tube_set(tubes)
      tube_set = Set.new
      tubes.keys.each do |key|
        tubes[key].each do |tube|
          tube_set.add(tube)
        end
      end
      tube_set
    end

  end
end
