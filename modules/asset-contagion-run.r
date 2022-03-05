# Initialize ----------------------------------------------------------
## Set Constants ----------------------------------------------------------
JOB_NAME = 'asset-contagion-run'
EF_DIR = Sys.getenv('EF_DIR')
IMPORT_DATE_START = '2014-01-01'
RESET_DATA = FALSE

## Cron Log ----------------------------------------------------------
if (interactive() == FALSE) {
	sink_path = file.path(EF_DIR, 'logs', paste0(JOB_NAME, '.log'))
	sink_conn = file(sink_path, open = 'at')
	system(paste0('echo "$(tail -50 ', sink_path, ')" > ', sink_path,''))
	lapply(c('output', 'message'), function(x) sink(sink_conn, append = T, type = x))
	message(paste0('\n\n----------- START ', format(Sys.time(), '%m/%d/%Y %I:%M %p ----------\n')))
}

## Load Libs ----------------------------------------------------------
library(tidyverse)
library(data.table)
library(jsonlite)
library(DBI)
library(RPostgres)
library(econforecasting)
library(lubridate)
library(roll)

## Load Connection Info ----------------------------------------------------------
source(file.path(EF_DIR, 'model-inputs', 'constants.r'))
db = dbConnect(
	RPostgres::Postgres(),
	dbname = CONST$DB_DATABASE,
	host = CONST$DB_SERVER,
	port = 5432,
	user = CONST$DB_USERNAME,
	password = CONST$DB_PASSWORD
)

# Get Data ----------------------------------------------------------
local({
	
	funds =
		tbl(db, sql('SELECT * FROM asset_contagion_funds')) %>%
		collect(.) %>%
		arrange(., id) %>%
		as.data.table(.)

	input_data =
		funds %>%
		purrr::transpose(.) %>%
		lapply(., function(x) {
			url =
				paste0(
					'https://query1.finance.yahoo.com/v7/finance/download/', x$ticker,
					'?period1=', as.numeric(as.POSIXct(as_date(IMPORT_DATE_START))),
					'&period2=', as.numeric(as.POSIXct(Sys.Date() + days(1))),
					'&interval=1d',
					'&events=history&includeAdjustedClose=true'
					)
			data.table::fread(url, showProgress = FALSE) %>%
				.[, c('Date', 'Adj Close')]	%>%
				set_names(., c('date', 'value')) %>%
				.[, value := (value/shift(value, 1) - 1) * 100] %>%
				.[2:nrow(.), ] %>%
				.[, c('usage', 'ticker') := list(x$usage, x$ticker)] %>%
				return(.)
			}) %>%
		rbindlist(.)
	
	funds <<- funds
	input_data <<- input_data
})


local({
	
	cor_values = lapply(unique(funds$usage), function(this_usage) {
		
		eligible_funds = funds[usage == this_usage]
		
		eligible_data = input_data[usage == this_usage][, usage := NULL]
		
		# Calculate all possible combinations of tickers; then merge data into it
		merged_data =
			cross_df(list(ticker_1 = 1:nrow(eligible_funds), ticker_2 = 1:nrow(eligible_funds))) %>%
			as.data.table(.) %>%
			.[ticker_2 > ticker_1] %>%
			.[, ticker_1 := map_chr(.$ticker_1, ~ eligible_funds[[., 'ticker']])] %>%
			.[, ticker_2 := map_chr(.$ticker_2, ~ eligible_funds[[., 'ticker']])] %>%
			# Rename on 
			merge(
				.,
				rename(eligible_data, value_1 = value),
				by.x = 'ticker_1', by.y = 'ticker', all = F, allow.cartesian = T
				) %>%
			merge(
				.,
				rename(eligible_data, value_2 = value),
				by.x = c('ticker_2', 'date'), by.y = c('ticker', 'date'), all = F, allow.cartesian = F
				)
	
		cors =
			merged_data %>%
			.[order(ticker_1, ticker_2, date)] %>%
			.[,
				c('cor_30', 'cor_60', 'cor_90') := list(
					roll_cor(value_1, value_2, width = 30),
					roll_cor(value_1, value_2, width = 60),
					roll_cor(value_1, value_2, width = 90)
					),
				by = c('ticker_1', 'ticker_2')
				] %>%
			melt(
				.,
				id.vars = c('date', 'ticker_1', 'ticker_2'),
				measure = patterns('cor_'),
				variable.name = 'window',
				value.name = 'value',
				variable.factor = FALSE,
				na.rm = TRUE
			) %>%
			.[, window := as.integer(str_sub(window, -2))] %>%
			.[, usage := this_usage]
		
		return(cors)
	})
	
})

# Calculate Correlations

	# Takes data frame of date, return, i.return
	# 1.27 seconds vs .3 seconds for roll_cor
	# calculateCorr30 = function(df) {
	# 	sapply(30:nrow(df), function(endRow)
	# 		df[(endRow-30):endRow] %>%
	# 			{cor(.[[2]], .[[3]])}
	# 		)
	# }
	# microbenchmark(calculateCorr30(df), times = 10)
	# microbenchmark(roll::roll_cor(df[[2]], df[[3]], width = 30))
	seriesAllDt =
		# Split by usage
		acFundDf %>%
		dplyr::group_by(usage) %>%
		dplyr::group_split(.) %>%
		setNames(., map(., ~ .$usage[[1]])) %>%
		purrr::imap(., function(acFundDfByUsage, usage) 
			# Get all combinations of tickers
			lapply(1:(length(acFundDfByUsage$ticker) - 1), function(n)
				lapply((n+1):length(acFundDfByUsage$ticker), function(m)
					list(ticker1 = acFundDfByUsage$ticker[[n]], ticker2 = acFundDfByUsage$ticker[[m]])
				)
			) %>%
				unlist(., recursive = FALSE) %>%
				# Calculate correlations
				purrr::imap_dfr(., function(x, i) {
					
					if (i %% 100 == 0) message(i)
					# Join raw data tables together
					dataDt =
						rawDataDfs[[paste0(usage, '.', x$ticker1)]][rawDataDfs[[paste0(usage, '.', x$ticker2)]], nomatch = 0, on = 'date']	
					
					seriesDt =
						dataDt %>%	
						# Calculate correlation starting with day 30
						.[, '30' := roll::roll_cor(dataDt[[2]], dataDt[[3]], width = 30)] %>%
						.[, '90' := roll::roll_cor(dataDt[[2]], dataDt[[3]], width = 90)] %>%
						.[, '180' := roll::roll_cor(dataDt[[2]], dataDt[[3]], width = 180)] %>%
						.[, -c('return', 'i.return')] %>%
						data.table::melt(
							.,
							id.vars = c('date'), variable.name = 'roll', value.name = 'value', variable.factor = FALSE,
							na.rm = TRUE
						) %>%
						.[, usage := usage] %>%
						.[, roll := as.numeric(roll)] %>%
						.[, method := 'p'] %>%
						.[, ticker1 := x$ticker1] %>%
						.[, ticker2 := x$ticker2]
					
					return(seriesDt)
				})
		) %>%
		dplyr::bind_rows(.)
	
	seriesAllRes =
		seriesAllDt %>%
		split(., by = c('usage', 'roll', 'method', 'ticker1', 'ticker2')) %>%
		lapply(., function(x) {
			
			fundSeriesMapDf =
				tibble(
					usage = x$usage[[1]],
					fk_fund1 = dplyr::filter(acFundDf, ticker == x$ticker1[[1]], usage == x$usage[[1]])$id,
					fk_fund2 = dplyr::filter(acFundDf, ticker == x$ticker2[[1]], usage == x$usage[[1]])$id,
					method = x$method[[1]],
					roll = x$roll[[1]],
					obs_start = min(x$date),
					obs_end = max(x$date),
					obs_count = nrow(x),
					last_updated = Sys.Date()
				) #%>%
			#dplyr::mutate(., nk = paste0(fk_fund1, '.', fk_fund2, '.', method, '.', window))
			
			seriesDf = x %>% .[, -c('roll', 'method', 'ticker1', 'ticker2', 'usage')]
			
			list(
				fundSeriesMapDf = fundSeriesMapDf,
				seriesDf = seriesDf
			)
		})
	
	
	fundSeriesMapDf = purrr::map_dfr(seriesAllRes, ~.$fundSeriesMapDf) 
	seriesAllRes <<- seriesAllRes
	fundSeriesMapDf <<- fundSeriesMapDf
})
```

# Calculate Correlation Index
```{r}
local({
	
	indexDf =
		seriesAllRes %>%
		purrr::keep(., ~.$fundSeriesMap[[1, 'roll']] == 90) %>%
		purrr::imap_dfr(., ~ .$seriesDf[, 'usage' := .$fundSeriesMap$usage[[1]]]) %>%
		.[, list(value = mean(value), count = .N), by = c('date', 'usage')] %>%
		.[, -c('count')] %>%
		.[, value := round(value, 4)] 
	
	# Consider filtering by dates where all obs available
	indexDf %>% ggplot(.) + geom_line(aes(x = date, y = value))
	
	
	indexDf <<- indexDf
})
```


# Send to SQL
```{r}
local({
	
	if (RESET_ALL == TRUE) {
		DBI::dbGetQuery(conn, 'TRUNCATE ac_fund_series_map RESTART IDENTITY CASCADE')
		DBI::dbGetQuery(conn, 'TRUNCATE ac_series')
		DBI::dbGetQuery(conn, 'TRUNCATE ac_index')
	}
	
	# Update ac_index
	query =
		paste0(
			'INSERT INTO ac_index (', paste0(colnames(indexDf), collapse = ','), ')\n',
			'VALUES\n',
			indexDf %>%
				dplyr::mutate_all(., ~ as.character(.)) %>%
				purrr::transpose(.) %>%
				lapply(., function(x) paste0(x, collapse = "','") %>% paste0("('", ., "')")) %>%
				paste0(., collapse = ', '),'\n',
			'ON CONFLICT ON CONSTRAINT ac_index_usage_date DO UPDATE SET value = EXCLUDED.value;'
		)
	
	DBI::dbGetQuery(conn, query)
	# Update last_updated if uniqueness constraint conflict
	query =
		paste0(
			'INSERT INTO ac_fund_series_map (', paste0(colnames(fundSeriesMapDf), collapse = ','), ')\n',
			'VALUES\n',
			fundSeriesMapDf %>%
				dplyr::mutate_all(., ~ as.character(.)) %>%
				purrr::transpose(.) %>%
				lapply(., function(x) paste0(x, collapse = "','") %>% paste0("('", ., "')")) %>%
				paste0(., collapse = ', '),'\n',
			'ON CONFLICT ON CONSTRAINT ac_fund_series_map_usage_method_roll_fk_fund1_fk_fund2 DO UPDATE SET last_updated = EXCLUDED.last_updated\n',
			'RETURNING id;'
		)
	idResults = DBI::dbGetQuery(conn, query)
	
	
	# Verify that inserted length is the same length as seriesAllRes
	if (length(idResults$id) != length(seriesAllRes)) stop('Error')
	
	# Get last date with series info for RESET_ALL = F
	lastDate =
		conn %>%
		DBI::dbGetQuery(., 'SELECT MAX(date) FROM ac_series') %>%
		.[[1, 1]]
	seriesDf =
		seriesAllRes %>%
		unname(.) %>%
		purrr::imap_dfr(., function(x, i)
			x$seriesDf[, fk_id := as.integer(idResults$id[[i]])]
		) %>%
		.[, value := round(value, 4)] %>%
		.[, date := as.character(date)] %>% {
			if (RESET_ALL == TRUE) .
			else .[date > lastDate]
		} %>%
		.[, usage := NULL]
	
	# If DF too big, use batch CSV
	if (nrow(seriesDf) >= 1e6) {
		message(Sys.time())
		
		tempPath = file.path(tempdir(), 'ac_series_data.csv')
		
		fwrite(seriesDf %>% .[,], tempPath)
		
		# Upload via SFTP
		RCurl::ftpUpload(
			what = tempPath,
			to = CONST$SFTP_PATH
		)
		
		unlink(tempPath)
		
		message(Sys.time())
		
		query =
			paste0(
				'COPY ac_series (date, value, fk_id)\n',
				'FROM \'/home/charles/ac_series_data.csv\' CSV HEADER;'
			)
		
		sqlRes = DBI::dbGetQuery(conn, query)
		message('Finished Bulk Insert: ', Sys.time())
	} else {
		
		# Split into 100k row pieces
		seriesInsertDfs =
			seriesDf %>%
			.[, splitIndex := floor(1:nrow(seriesDf)/.1e6)] %>%
			split(., by = 'splitIndex', keep.by = FALSE) %>% unname(.)
		
		
		purrr::imap(seriesInsertDfs, function(seriesInsertDf, i) {
			
			if (i %% 50 == 0) message(i)
			
			query =
				paste0(
					'INSERT INTO ac_series (date, value, fk_id)\n',
					'VALUES\n',
					seriesInsertDf %>%
						.[, value := round(value, 4)] %>%
						.[, date := as.character(date)] %>%
						purrr::transpose(.) %>%
						lapply(., function(x) paste0(x, collapse = "','") %>% paste0("('", ., "')")) %>%
						paste0(., collapse = ', '),';'
				)
			
			message(Sys.time())
			res = DBI::dbGetQuery(conn, query)
			message(Sys.time())
			
		})
	}
	
})
```


# S&P 500 (In Devleopment)
```{r eval=FALSE, include=FALSE}
local({
	
	dir = file.path(DL_DIR, 'sp500')
	if (dir.exists(dir)) unlink(dir, recursive = TRUE)
	dir.create(dir, recursive = TRUE)
	# Get list of S&P 500 stocks
	sp500StockList =
		httr::GET('https://en.wikipedia.org/wiki/List_of_S%26P_500_companies#Selected_changes_to_the_list_of_S&P_500_components') %>%
		httr::content(., as = 'parsed') %>%
		rvest::html_node(., '#constituents') %>% rvest::html_table(., header = TRUE, fill = FALSE) %>%
		dplyr::transmute(., ticker = str_replace(Symbol, coll('.'), '-'), longname = Security, sector = .$'GICS Sector') %>%
		as_tibble(.) %>%
		dplyr::arrange(., sector, ticker) %>%
		dplyr::mutate(., order = 0:(nrow(.) - 1), filepath = file.path(dir, paste0(order, '.csv')))
	rawDataDfs =
		sp500StockList %>%
		purrr::transpose(.) %>%
		setNames(., lapply(., function(x) x$ticker)) %>%
		lapply(., function(x) {
			
			#message(x$ticker)
			if (x$order %% 100 == 0) message(x$order)
			url =
				paste0(
					'https://query1.finance.yahoo.com/v7/finance/download/', x$ticker,
					'?period1=', as.numeric(as.POSIXct(Sys.Date() - lubridate::days(50))), # Enough to get last 30 market days
					'&period2=', as.numeric(as.POSIXct(Sys.Date() + lubridate::days(1))),
					'&interval=1d',
					'&events=history&includeAdjustedClose=true'
				)
			httr::RETRY(
				verb = 'GET',
				url = url,
				httr::write_disk(x$filepath)
			)
			
			df =
				data.table::fread(x$filepath) %>%
				.[, c('Date', 'Adj Close')]	%>%
				setnames(., new = c('date', 'price'))
			
			# Quit if last row is empty (occurs when company has been aquired but not yet removed from wikipedia list of stocks)
			if (!is.numeric(df[[nrow(df), 'price']])) return(NA)
			
			df %>%
				.[, lag := shift(price, 1)] %>%
				.[, return := (price/lag - 1) * 100] %>%
				.[, -c('price', 'lag')] %>%
				.[(nrow(.) - 29):nrow(.), ] %>%
				return(.)
		}) %>%
		# Reject all NA results (see above)
		purrr::keep(., ~ is.data.table(.))
	
	unlink(dir, recursive = TRUE)
	seriesAllDt =
		# Get all combinations of tickers
		lapply(1:(length(sp500StockList$ticker) - 1), function(n)
			lapply((n+1):length(sp500StockList$ticker), function(m)
				list(ticker1 = sp500StockList$ticker[[n]], ticker2 = sp500StockList$ticker[[m]]))
		) %>%
		unlist(., recursive = FALSE) %>%
		# Only keep if data was available
		purrr::keep(., ~ .$ticker1 %in% names(rawDataDfs) && .$ticker2 %in% names(rawDataDfs)) %>%
		purrr::imap(., function(x, i) {
			
			if (i %% 5000 == 0) message(i)
			# Join raw data tables together
			dataDt = rawDataDfs[[x$ticker1]][rawDataDfs[[x$ticker2]], nomatch = 0, on = 'date']
			seriesDt =
				dataDt %>%
				# Calculate correlation starting with day 30
				.[, '30' := roll::roll_cor(dataDt[[2]], dataDt[[3]], width = 30)] %>%
				.[, -c('return', 'i.return')] %>%
				data.table::melt(
					.,
					id.vars = c('date'), variable.name = 'roll', value.name = 'value', variable.factor = FALSE,
					na.rm = TRUE
				) %>%
				.[, ticker1 := x$ticker1] %>%
				.[, ticker2 := x$ticker2]
			return(seriesDt)
		}) %>%
		dplyr::bind_rows(.)
	seriesAllRes =
		seriesAllDt %>%
		split(., by = c('ticker1', 'ticker2')) %>%
		lapply(., function(x) {
			fundSeriesMapDf =
				tibble(
					ticker1 = x$ticker1,
					order1 = dplyr::filter(sp500StockList, ticker == x$ticker1[[1]])$order,
					category1 = dplyr::filter(sp500StockList, ticker == x$ticker1[[1]])$sector,
					ticker2 = x$ticker2,
					order2 = dplyr::filter(sp500StockList, ticker == x$ticker2[[1]])$order,
					category2 = dplyr::filter(sp500StockList, ticker == x$ticker1[[1]])$sector,
					last_updated = Sys.Date()
				)
			seriesDf = x %>% .[, -c('ticker1', 'ticker2')]
			list(
				fundSeriesMapDf = fundSeriesMapDf,
				seriesDf = seriesDf
			)
		})
	fundSeriesMapDf = purrr::map_dfr(seriesAllRes, ~.$fundSeriesMapDf) %>% dplyr::mutate(., usage = 'sp500')
	
})
```

