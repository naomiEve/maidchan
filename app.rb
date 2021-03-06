require 'sinatra'
require 'sanitize'
require 'sqlite3'
require 'digest'

db = SQLite3::Database.new "maidchan.db"

# Configuration (Janitors, etc...)
config_raw = File.read('./config.json')
config = JSON.parse(config_raw)

enable :sessions

set :config, config
set :public_folder, File.dirname(__FILE__) + '/static'
set :port, 80
set :bind, '0.0.0.0'

# Helper functions
types = ['image/png', 'image/jpeg', 'image/gif', 'video/webm']

def get_ip(req, env) #Gets the ip of the user
	ip = req.ip
	if ip == "127.0.0.1"
		ip = env["HTTP_X_FORWARDED_FOR"]
	end
	return ip
end

def tripcode!(trip) #Generates a hash out of a tripcode
	return Digest::SHA256.base64digest(trip)[0..10]
end

def store!(params) #Stores the file and returns the filename
	digest = Digest::MD5.new
	digest << params[:file][:filename]
	filename = digest.hexdigest + "." + params[:file][:type].split("/")[1]

	File.open("./static/uploads/#{filename}", "wb") do |file|
		file.write(params[:file][:tempfile].read)
	end
	return filename
end

def delete!(id, db)
	files = []

	db.execute("SELECT * FROM posts WHERE post_id=? OR parent=?", id, id).each do |row| #Gather image data for deletion.
		unless row[4].nil?
			files.push(row[4])
		end
	end

	db.execute("DELETE FROM posts WHERE post_id=? OR parent=?", id, id)
	db.execute("VACUUM")

	if files.length > 0
		files.each do |file|
			File.delete("./static/uploads/#{file}")
		end
	end
end

def ban!(ip, reason, date, db)
	old_date = date.split('/') #Shady date formatting code
	formatted_date = old_date[2] + "-" + old_date[0] + "-" + old_date[1] + " 00:00:00"

	db.execute("INSERT INTO bans (ip, reason, unban_date) VALUES (?, ?, ?)", ip, reason, formatted_date)	
end

def is_moderator?(session)
	return !session[:moderator].nil?
end

def is_banned?(ip, db)
	#puts "the ip is: " + ip
	puts "in is_banned"
	db.execute("SELECT * FROM bans WHERE ip=? AND unban_date > CURRENT_TIMESTAMP", ip).each do |row| #Check if there is a ban that is still in progress (the date of unban is bigger than the current timestamp)
		puts "found a valid candidate"
		return true # Return yes on any row that is returned
		puts "something went wrong" 
	end

	puts "nothing was found"
	return false # Return no if there were no bans found
end

# GET requests, A.K.A. regular routes

get '/' do
	erb :index, :locals => {:db => db, :session => session}	
end

get '/topic/:id' do |id|
	erb :topic, :locals => {:db => db, :id => id.to_i, :session => session}
end

# GET moderation actions

get '/mod' do
	erb :login
end

get '/logout' do
	session[:moderator] = nil
	redirect '/mod', 303
end

get '/delete/:id' do |id|
	if is_moderator?(session)
		delete! id.to_i, db
		return[200, "Success, probably"]	
	else
		return[403, "You're not a moderator."]
	end
end

get '/ban/:ip' do |ip|
	if is_moderator?(session)
		erb :ban, :locals => {:ip => ip}
	else
		return[403, "You're not a moderator."]
	end
end

# POST requests, A.K.A. functional routes

post '/post' do
	if is_banned?(get_ip(request, env), db)
		return [403, "You're banned."]
	end

        unless params[:name].empty? or params[:name].length > 40
                splitted = params[:name].split('#')

                unless splitted[1].nil?
                        name = splitted[0] + "!" + tripcode!(splitted[1])
                else
                        name = splitted[0]
                end
        else
                name = "Anonymous"
        end

	if params[:comment].length > 2000 or params[:title].length > 100
		return[431, "Post or title too long"]
	end

	if params[:file] and types.include?(params[:file][:type]) and params[:file][:tempfile].size < 3145728
		filename = store!(params)
		db.execute("INSERT INTO posts (title, comment, author, image, ip) VALUES (?, ?, ?, ?, ?)", params[:title], params[:comment], name, filename, get_ip(request, env))
	else
		db.execute("INSERT INTO posts (title, comment, author, ip) VALUES (?, ?, ?, ?)", params[:title], params[:comment], name, get_ip(request, env))
	end	
	redirect '/', 303
end

post '/reply/:id' do |id|
	if is_banned?(get_ip(request, env), db)
		return [403, "You're banned."]
	end

	db.execute("UPDATE posts SET date_of_bump=CURRENT_TIMESTAMP WHERE post_id=?", id.to_i)

	unless params[:name].empty? or params[:name].length > 40
		splitted = params[:name].split('#')
							
		unless splitted[1].nil?
			name = splitted[0] + "!" + tripcode!(splitted[1])
		else
			name = splitted[0]
		end
	else
		name = "Anonymous"
	end

	if params[:comment].length > 2000
		return[431, "Post too long, over 2000 characters."]
	end

	if params[:file] and types.include?(params[:file][:type]) and params[:file][:tempfile].size < 3145728
		filename = store!(params)
		db.execute("INSERT INTO posts (parent, comment, author, image, ip) VALUES (?, ?, ?, ?, ?)", id.to_i, params[:comment], name, filename, get_ip(request, env))
	else
		db.execute("INSERT INTO posts (parent, comment, author, ip) VALUES (?, ?, ?, ?)", id.to_i, params[:comment], name, get_ip(request, env))
	end
	redirect '/topic/' + id, 303
end

post '/mod' do
	if config["janitors"][params[:name]] and config["janitors"][params[:name]]["pass"] == params[:pass]
		session[:moderator] = params[:name]
		redirect '/', 303
	else
		return[401, "Invalid username or password."]
	end
end

post '/ban/:ip' do |ip|
	if is_moderator?(session)
		ban!(ip, params[:reason], params[:date], db)
		return[200, "OK"]
	else
		return[403, "You're not a moderator."]
	end	
end
